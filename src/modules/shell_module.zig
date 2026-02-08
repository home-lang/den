const std = @import("std");
const IO = @import("../utils/io.zig").IO;

/// Represents a user-defined shell module created via:
///   module <name> { def <cmd> [args] { body } }
///
/// A ShellModule holds exported commands (mapping command names to their body
/// lines) and exported variables (mapping variable names to string values).
/// Modules can be loaded into the current shell session with `use <name>` or
/// `use <name> [cmd1, cmd2]` for selective imports.
pub const ShellModule = struct {
    /// Module name, e.g. "math"
    name: []const u8,

    /// Exported commands: command_name -> list of body lines.
    /// Each body line is the raw text inside the `def` block.
    commands: std.StringHashMap(std.ArrayList([]const u8)),

    /// Exported variables: variable_name -> value string.
    variables: std.StringHashMap([]const u8),

    /// Whether this module has been fully loaded/initialized.
    loaded: bool,

    /// Source path if the module was loaded from a file, null if defined inline.
    source_path: ?[]const u8,

    /// Create a new, empty ShellModule with the given name.
    /// The name is duped into the provided allocator.
    pub fn init(allocator: std.mem.Allocator, name: []const u8) !ShellModule {
        return .{
            .name = try allocator.dupe(u8, name),
            .commands = std.StringHashMap(std.ArrayList([]const u8)).empty,
            .variables = std.StringHashMap([]const u8).empty,
            .loaded = false,
            .source_path = null,
        };
    }

    /// Free all memory owned by this module.
    pub fn deinit(self: *ShellModule, allocator: std.mem.Allocator) void {
        // Free command entries: each key is a duped string, each value is
        // an ArrayList of duped body-line strings.
        var cmd_iter = self.commands.iterator();
        while (cmd_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |line| {
                allocator.free(line);
            }
            entry.value_ptr.deinit(allocator);
        }
        self.commands.deinit(allocator);

        // Free variable entries.
        var var_iter = self.variables.iterator();
        while (var_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.variables.deinit(allocator);

        if (self.source_path) |sp| {
            allocator.free(sp);
        }
        allocator.free(self.name);
    }

    /// Define (or redefine) a command inside this module.
    ///
    /// `name` is the command name (e.g. "add"), `body_lines` is a slice
    /// of the raw body lines from the `def` block. Both the name and each
    /// line are duped.
    pub fn defineCommand(self: *ShellModule, allocator: std.mem.Allocator, name: []const u8, body_lines: []const []const u8) !void {
        // If the command already exists, free the old entry.
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
            const duped = try allocator.dupe(u8, line);
            try lines.append(allocator, duped);
        }

        const key = try allocator.dupe(u8, name);
        try self.commands.put(allocator, key, lines);
    }

    /// Export a variable from this module.
    /// Both name and value are duped.
    pub fn exportVariable(self: *ShellModule, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        // If the variable already exists, free the old entry.
        if (self.variables.fetchRemove(name)) |removed| {
            allocator.free(removed.key);
            allocator.free(removed.value);
        }

        const key = try allocator.dupe(u8, name);
        const val = try allocator.dupe(u8, value);
        try self.variables.put(allocator, key, val);
    }

    /// Look up a command by name and return its body lines, or null.
    pub fn getCommand(self: *const ShellModule, name: []const u8) ?[]const []const u8 {
        if (self.commands.get(name)) |lines| {
            return lines.items;
        }
        return null;
    }

    /// Look up a variable by name and return its value, or null.
    pub fn getVariable(self: *const ShellModule, name: []const u8) ?[]const u8 {
        return self.variables.get(name);
    }

    /// Return a list of all exported command names.
    /// Caller owns the returned slice but NOT the individual strings
    /// (they are borrowed from the module).
    pub fn listCommands(self: *const ShellModule, allocator: std.mem.Allocator) ![]const []const u8 {
        var names: std.ArrayList([]const u8) = .{
            .items = &[_][]const u8{},
            .capacity = 0,
        };
        var iter = self.commands.iterator();
        while (iter.next()) |entry| {
            try names.append(allocator, entry.key_ptr.*);
        }
        return try names.toOwnedSlice(allocator);
    }

    /// Return a list of all exported variable names.
    /// Caller owns the returned slice but NOT the individual strings.
    pub fn listVariables(self: *const ShellModule, allocator: std.mem.Allocator) ![]const []const u8 {
        var names: std.ArrayList([]const u8) = .{
            .items = &[_][]const u8{},
            .capacity = 0,
        };
        var iter = self.variables.iterator();
        while (iter.next()) |entry| {
            try names.append(allocator, entry.key_ptr.*);
        }
        return try names.toOwnedSlice(allocator);
    }

    /// Mark the module as loaded.
    pub fn markLoaded(self: *ShellModule) void {
        self.loaded = true;
    }
};

/// Global module store -- holds all defined modules by name.
/// Used by the shell executor to resolve `module { ... }` definitions and
/// `use <name>` imports.
pub const ModuleStore = struct {
    modules: std.StringHashMap(ShellModule),

    pub fn init() ModuleStore {
        return .{
            .modules = std.StringHashMap(ShellModule).empty,
        };
    }

    pub fn deinit(self: *ModuleStore, allocator: std.mem.Allocator) void {
        var iter = self.modules.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.modules.deinit(allocator);
    }

    /// Register a new module. If a module with the same name already exists
    /// it is replaced (old module is freed).
    pub fn register(self: *ModuleStore, allocator: std.mem.Allocator, module: ShellModule) !void {
        // If there is an existing module under this name, free it.
        if (self.modules.fetchRemove(module.name)) |removed| {
            allocator.free(removed.key);
            var old = removed.value;
            old.deinit(allocator);
        }

        const key = try allocator.dupe(u8, module.name);
        try self.modules.put(allocator, key, module);
    }

    /// Look up a module by name.
    pub fn get(self: *const ModuleStore, name: []const u8) ?*const ShellModule {
        return self.modules.getPtr(name);
    }

    /// Look up a module by name (mutable).
    pub fn getMut(self: *ModuleStore, name: []const u8) ?*ShellModule {
        return self.modules.getPtr(name);
    }

    /// Remove a module by name. Returns true if removed, false if not found.
    pub fn remove(self: *ModuleStore, allocator: std.mem.Allocator, name: []const u8) bool {
        if (self.modules.fetchRemove(name)) |removed| {
            allocator.free(removed.key);
            var old = removed.value;
            old.deinit(allocator);
            return true;
        }
        return false;
    }

    /// Return a list of all registered module names.
    /// Caller owns the returned slice but NOT the individual strings.
    pub fn listModules(self: *const ModuleStore, allocator: std.mem.Allocator) ![]const []const u8 {
        var names: std.ArrayList([]const u8) = .{
            .items = &[_][]const u8{},
            .capacity = 0,
        };
        var iter = self.modules.iterator();
        while (iter.next()) |entry| {
            try names.append(allocator, entry.key_ptr.*);
        }
        return try names.toOwnedSlice(allocator);
    }

    /// Check whether a module with the given name exists.
    pub fn contains(self: *const ModuleStore, name: []const u8) bool {
        return self.modules.contains(name);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ShellModule define and lookup command" {
    const allocator = std.testing.allocator;

    var module = try ShellModule.init(allocator, "math");
    defer module.deinit(allocator);

    const body = &[_][]const u8{ "expr $a + $b" };
    try module.defineCommand(allocator, "add", body);

    const cmd = module.getCommand("add");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("expr $a + $b", cmd.?[0]);
}

test "ShellModule export and lookup variable" {
    const allocator = std.testing.allocator;

    var module = try ShellModule.init(allocator, "config");
    defer module.deinit(allocator);

    try module.exportVariable(allocator, "PI", "3.14159");
    const val = module.getVariable("PI");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("3.14159", val.?);
}

test "ShellModule redefine command replaces old" {
    const allocator = std.testing.allocator;

    var module = try ShellModule.init(allocator, "math");
    defer module.deinit(allocator);

    const body1 = &[_][]const u8{ "expr $a + $b" };
    try module.defineCommand(allocator, "add", body1);

    const body2 = &[_][]const u8{ "echo $(( $a + $b ))" };
    try module.defineCommand(allocator, "add", body2);

    const cmd = module.getCommand("add");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("echo $(( $a + $b ))", cmd.?[0]);
}

test "ModuleStore register and lookup" {
    const allocator = std.testing.allocator;

    var store = ModuleStore.init();
    defer store.deinit(allocator);

    var module = try ShellModule.init(allocator, "utils");
    module.markLoaded();
    try store.register(allocator, module);

    try std.testing.expect(store.contains("utils"));
    try std.testing.expect(!store.contains("nonexistent"));

    const m = store.get("utils");
    try std.testing.expect(m != null);
    try std.testing.expect(m.?.loaded);
}

test "ModuleStore remove" {
    const allocator = std.testing.allocator;

    var store = ModuleStore.init();
    defer store.deinit(allocator);

    var module = try ShellModule.init(allocator, "temp");
    try store.register(allocator, module);

    try std.testing.expect(store.contains("temp"));
    try std.testing.expect(store.remove(allocator, "temp"));
    try std.testing.expect(!store.contains("temp"));
    try std.testing.expect(!store.remove(allocator, "temp"));
}

test "ShellModule listCommands" {
    const allocator = std.testing.allocator;

    var module = try ShellModule.init(allocator, "math");
    defer module.deinit(allocator);

    try module.defineCommand(allocator, "add", &[_][]const u8{"expr $a + $b"});
    try module.defineCommand(allocator, "sub", &[_][]const u8{"expr $a - $b"});

    const names = try module.listCommands(allocator);
    defer allocator.free(names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
}
