const std = @import("std");
const Shell = @import("../shell.zig").Shell;
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;

// Re-export builtin modules
pub const filesystem = @import("filesystem.zig");
pub const directory = @import("directory.zig");
pub const io_builtins = @import("io.zig");
pub const process = @import("process.zig");
pub const variables = @import("variables.zig");
pub const misc = @import("misc.zig");

/// Builtin function type signature
pub const BuiltinFn = *const fn (shell: *Shell, cmd: *types.ParsedCommand) anyerror!void;

/// Builtin command registry
pub const BuiltinRegistry = struct {
    allocator: std.mem.Allocator,
    builtins: std.StringHashMap(BuiltinFn),
    disabled: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) BuiltinRegistry {
        return .{
            .allocator = allocator,
            .builtins = std.StringHashMap(BuiltinFn).init(allocator),
            .disabled = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *BuiltinRegistry) void {
        self.builtins.deinit();
        var iter = self.disabled.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.disabled.deinit();
    }

    /// Register a builtin command
    pub fn register(self: *BuiltinRegistry, name: []const u8, func: BuiltinFn) !void {
        try self.builtins.put(name, func);
    }

    /// Check if a builtin exists
    pub fn hasBuiltin(self: *const BuiltinRegistry, name: []const u8) bool {
        return self.builtins.contains(name);
    }

    /// Check if a builtin is enabled
    pub fn isEnabled(self: *const BuiltinRegistry, name: []const u8) bool {
        return self.builtins.contains(name) and !self.disabled.contains(name);
    }

    /// Execute a builtin command
    pub fn execute(self: *BuiltinRegistry, shell: *Shell, cmd: *types.ParsedCommand) !bool {
        if (self.disabled.contains(cmd.name)) {
            return false; // Disabled builtin, fall through to external command
        }

        if (self.builtins.get(cmd.name)) |func| {
            try func(shell, cmd);
            return true;
        }
        return false;
    }

    /// Disable a builtin
    pub fn disable(self: *BuiltinRegistry, name: []const u8) !void {
        if (self.builtins.contains(name)) {
            const name_copy = try self.allocator.dupe(u8, name);
            try self.disabled.put(name_copy, {});
        }
    }

    /// Enable a previously disabled builtin
    pub fn enable(self: *BuiltinRegistry, name: []const u8) void {
        if (self.disabled.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Get list of all builtins
    pub fn getAllBuiltins(self: *const BuiltinRegistry, allocator: std.mem.Allocator) ![][]const u8 {
        var list = std.array_list.Managed([]const u8).init(allocator);
        var iter = self.builtins.keyIterator();
        while (iter.next()) |key| {
            try list.append(key.*);
        }
        return list.toOwnedSlice();
    }

    /// Get list of disabled builtins
    pub fn getDisabledBuiltins(self: *const BuiltinRegistry, allocator: std.mem.Allocator) ![][]const u8 {
        var list = std.array_list.Managed([]const u8).init(allocator);
        var iter = self.disabled.keyIterator();
        while (iter.next()) |key| {
            try list.append(key.*);
        }
        return list.toOwnedSlice();
    }
};

/// Initialize the builtin registry with all standard builtins
pub fn initStandardBuiltins(registry: *BuiltinRegistry) !void {
    // Filesystem builtins
    try registry.register("basename", filesystem.basename);
    try registry.register("dirname", filesystem.dirname);
    try registry.register("realpath", filesystem.realpath);

    // Directory builtins
    try registry.register("pushd", directory.pushd);
    try registry.register("popd", directory.popd);
    try registry.register("dirs", directory.dirs);

    // I/O builtins
    try registry.register("printf", io_builtins.printf);
    try registry.register("read", io_builtins.read);

    // Process builtins
    try registry.register("exec", process.exec);
    try registry.register("wait", process.wait);
    try registry.register("kill", process.kill);
    try registry.register("disown", process.disown);

    // Variable builtins
    try registry.register("local", variables.local);
    try registry.register("declare", variables.declare);
    try registry.register("readonly", variables.readonly);
    try registry.register("typeset", variables.typeset);
    try registry.register("let", variables.let);

    // Misc builtins
    try registry.register("sleep", misc.sleep);
    try registry.register("help", misc.help);
    try registry.register("clear", misc.clear);
    try registry.register("uname", misc.uname);
    try registry.register("whoami", misc.whoami);
    try registry.register("umask", misc.umask);
    try registry.register("time", misc.time);
    try registry.register("caller", misc.caller);
}
