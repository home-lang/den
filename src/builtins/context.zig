const std = @import("std");
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;

/// Context passed to builtin commands
/// Provides access to shell state without tight coupling
pub const BuiltinContext = struct {
    allocator: std.mem.Allocator,
    environment: *std.StringHashMap([]const u8),
    aliases: *std.StringHashMap([]const u8),
    variables: *std.StringHashMap([]const u8),
    var_attributes: *std.StringHashMap(types.VarAttributes),
    directory_stack: *std.ArrayList([]const u8),
    last_exit_code: *i32,
    positional_params: []const []const u8,

    // Callbacks for shell operations that builtins may need
    executeCommandFn: ?*const fn (*anyopaque, []const u8) anyerror!void,
    shell_ptr: ?*anyopaque,

    pub fn setExitCode(self: *BuiltinContext, code: i32) void {
        self.last_exit_code.* = code;
    }

    pub fn getExitCode(self: *const BuiltinContext) i32 {
        return self.last_exit_code.*;
    }

    pub fn executeCommand(self: *BuiltinContext, cmd: []const u8) !void {
        if (self.executeCommandFn) |func| {
            if (self.shell_ptr) |ptr| {
                try func(ptr, cmd);
            }
        }
    }

    pub fn getEnv(self: *const BuiltinContext, key: []const u8) ?[]const u8 {
        return self.environment.get(key);
    }

    pub fn setEnv(self: *BuiltinContext, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const val_copy = try self.allocator.dupe(u8, value);
        try self.environment.put(key_copy, val_copy);
    }

    pub fn getVariable(self: *const BuiltinContext, name: []const u8) ?[]const u8 {
        return self.variables.get(name);
    }

    pub fn setVariable(self: *BuiltinContext, name: []const u8, value: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        const val_copy = try self.allocator.dupe(u8, value);
        try self.variables.put(name_copy, val_copy);
    }
};

/// Result of a builtin execution
pub const BuiltinResult = struct {
    exit_code: i32,
    output: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

/// Builtin function signature
pub const BuiltinFn = *const fn (*BuiltinContext, *types.ParsedCommand) anyerror!BuiltinResult;
