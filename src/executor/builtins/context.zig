const std = @import("std");
const types = @import("../../types/mod.zig");
const Shell = @import("../../shell.zig").Shell;
const ScriptResult = @import("../../scripting/script_manager.zig").ScriptResult;

/// BuiltinContext provides a unified interface for builtins to access shell state.
/// This decouples builtins from the Executor implementation, enabling better
/// modularity and testability.
pub const BuiltinContext = struct {
    allocator: std.mem.Allocator,
    environment: *std.StringHashMap([]const u8),
    shell: ?*Shell,

    /// Create a context from an allocator, environment, and optional shell reference
    pub fn init(
        allocator: std.mem.Allocator,
        environment: *std.StringHashMap([]const u8),
        shell: ?*Shell,
    ) BuiltinContext {
        return .{
            .allocator = allocator,
            .environment = environment,
            .shell = shell,
        };
    }

    // ============ Environment Operations ============

    /// Get an environment variable value
    pub fn getEnv(self: *const BuiltinContext, name: []const u8) ?[]const u8 {
        return self.environment.get(name);
    }

    /// Set an environment variable (allocates both key and value)
    pub fn setEnv(self: *BuiltinContext, name: []const u8, value: []const u8) !void {
        const gop = try self.environment.getOrPut(name);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = try self.allocator.dupe(u8, value);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, name);
            gop.value_ptr.* = try self.allocator.dupe(u8, value);
        }
    }

    /// Unset an environment variable
    pub fn unsetEnv(self: *BuiltinContext, name: []const u8) void {
        if (self.environment.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    /// Get environment iterator
    pub fn envIterator(self: *const BuiltinContext) std.StringHashMap([]const u8).Iterator {
        return self.environment.iterator();
    }

    // ============ Shell State Access ============

    /// Check if shell context is available
    pub fn hasShell(self: *const BuiltinContext) bool {
        return self.shell != null;
    }

    /// Get shell reference (returns error if not available)
    pub fn getShell(self: *const BuiltinContext) !*Shell {
        return self.shell orelse error.NoShellContext;
    }

    // ============ Alias Operations ============

    /// Get an alias value
    pub fn getAlias(self: *const BuiltinContext, name: []const u8) ?[]const u8 {
        const shell_ref = self.shell orelse return null;
        return shell_ref.aliases.get(name);
    }

    /// Set an alias
    pub fn setAlias(self: *BuiltinContext, name: []const u8, value: []const u8) !void {
        const shell_ref = self.shell orelse return error.NoShellContext;
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);
        const value_owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_owned);

        const gop = try shell_ref.aliases.getOrPut(name_owned);
        if (gop.found_existing) {
            self.allocator.free(name_owned);
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = value_owned;
        } else {
            gop.value_ptr.* = value_owned;
        }
    }

    /// Remove an alias
    pub fn removeAlias(self: *BuiltinContext, name: []const u8) bool {
        const shell_ref = self.shell orelse return false;
        if (shell_ref.aliases.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
            return true;
        }
        return false;
    }

    /// Get alias iterator
    pub fn aliasIterator(self: *const BuiltinContext) ?std.StringHashMap([]const u8).Iterator {
        const shell_ref = self.shell orelse return null;
        return shell_ref.aliases.iterator();
    }

    /// Clear all aliases
    pub fn clearAliases(self: *BuiltinContext) void {
        const shell_ref = self.shell orelse return;
        var iter = shell_ref.aliases.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        shell_ref.aliases.clearRetainingCapacity();
    }

    // ============ Array Operations ============

    /// Get an array by name
    pub fn getArray(self: *const BuiltinContext, name: []const u8) ?[][]const u8 {
        const shell_ref = self.shell orelse return null;
        return shell_ref.arrays.get(name);
    }

    /// Set an array (takes ownership of the slice)
    pub fn setArray(self: *BuiltinContext, name: []const u8, values: [][]const u8) !void {
        const shell_ref = self.shell orelse return error.NoShellContext;

        // Remove old array if exists
        if (shell_ref.arrays.fetchRemove(name)) |old| {
            for (old.value) |elem| {
                self.allocator.free(elem);
            }
            self.allocator.free(old.value);
            self.allocator.free(old.key);
        }

        const key = try self.allocator.dupe(u8, name);
        try shell_ref.arrays.put(key, values);
    }

    /// Remove an array
    pub fn removeArray(self: *BuiltinContext, name: []const u8) bool {
        const shell_ref = self.shell orelse return false;
        if (shell_ref.arrays.fetchRemove(name)) |old| {
            for (old.value) |elem| {
                self.allocator.free(elem);
            }
            self.allocator.free(old.value);
            self.allocator.free(old.key);
            return true;
        }
        return false;
    }

    // ============ Directory Stack Operations ============

    /// Get current directory stack count
    pub fn dirStackCount(self: *const BuiltinContext) usize {
        const shell_ref = self.shell orelse return 0;
        return shell_ref.dir_stack_count;
    }

    /// Get directory at stack index (0 = bottom)
    pub fn getDirAt(self: *const BuiltinContext, index: usize) ?[]const u8 {
        const shell_ref = self.shell orelse return null;
        if (index >= shell_ref.dir_stack_count) return null;
        return shell_ref.dir_stack[index];
    }

    /// Push directory onto stack
    pub fn pushDir(self: *BuiltinContext, dir: []const u8) !void {
        const shell_ref = self.shell orelse return error.NoShellContext;
        if (shell_ref.dir_stack_count >= shell_ref.dir_stack.len) {
            return error.DirStackFull;
        }
        shell_ref.dir_stack[shell_ref.dir_stack_count] = try self.allocator.dupe(u8, dir);
        shell_ref.dir_stack_count += 1;
    }

    /// Pop directory from stack
    pub fn popDir(self: *BuiltinContext) ?[]const u8 {
        const shell_ref = self.shell orelse return null;
        if (shell_ref.dir_stack_count == 0) return null;
        shell_ref.dir_stack_count -= 1;
        const dir = shell_ref.dir_stack[shell_ref.dir_stack_count];
        shell_ref.dir_stack[shell_ref.dir_stack_count] = null;
        return dir;
    }

    /// Update directory at stack index
    pub fn updateDirAt(self: *BuiltinContext, index: usize, dir: []const u8) !void {
        const shell_ref = self.shell orelse return error.NoShellContext;
        if (index >= shell_ref.dir_stack_count) return error.InvalidIndex;
        if (shell_ref.dir_stack[index]) |old| {
            self.allocator.free(old);
        }
        shell_ref.dir_stack[index] = try self.allocator.dupe(u8, dir);
    }

    // ============ History Operations ============

    /// Get history count
    pub fn historyCount(self: *const BuiltinContext) usize {
        const shell_ref = self.shell orelse return 0;
        return shell_ref.history_count;
    }

    /// Get history entry at index
    pub fn getHistoryAt(self: *const BuiltinContext, index: usize) ?[]const u8 {
        const shell_ref = self.shell orelse return null;
        if (index >= shell_ref.history_count) return null;
        return shell_ref.history[index];
    }

    // ============ Variable Attributes ============

    /// Get variable attributes
    pub fn getVarAttributes(self: *const BuiltinContext, name: []const u8) ?types.VarAttributes {
        const shell_ref = self.shell orelse return null;
        return shell_ref.var_attributes.get(name);
    }

    /// Set variable attributes
    pub fn setVarAttributes(self: *BuiltinContext, name: []const u8, attrs: types.VarAttributes) !void {
        const shell_ref = self.shell orelse return error.NoShellContext;
        const gop = try shell_ref.var_attributes.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, name);
        }
        gop.value_ptr.* = attrs;
    }

    // ============ Associative Array Operations ============

    /// Get associative array
    pub fn getAssocArray(self: *const BuiltinContext, name: []const u8) ?std.StringHashMap([]const u8) {
        const shell_ref = self.shell orelse return null;
        return shell_ref.assoc_arrays.get(name);
    }

    // ============ Job Manager Access ============

    /// Execute jobs builtin through job manager
    pub fn builtinJobs(self: *const BuiltinContext, args: [][]const u8) !i32 {
        const shell_ref = self.shell orelse return error.NoShellContext;
        return try shell_ref.job_manager.builtinJobs(args);
    }

    /// Execute fg builtin through job manager
    pub fn builtinFg(self: *const BuiltinContext, args: [][]const u8) !i32 {
        const shell_ref = self.shell orelse return error.NoShellContext;
        return try shell_ref.job_manager.builtinFg(args);
    }

    /// Execute bg builtin through job manager
    pub fn builtinBg(self: *const BuiltinContext, args: [][]const u8) !i32 {
        const shell_ref = self.shell orelse return error.NoShellContext;
        return try shell_ref.job_manager.builtinBg(args);
    }

    /// Execute wait builtin through job manager
    pub fn builtinWait(self: *const BuiltinContext, args: [][]const u8) !i32 {
        const shell_ref = self.shell orelse return error.NoShellContext;
        return try shell_ref.job_manager.builtinWait(args);
    }

    /// Execute disown builtin through job manager
    pub fn builtinDisown(self: *const BuiltinContext, args: [][]const u8) !i32 {
        const shell_ref = self.shell orelse return error.NoShellContext;
        return try shell_ref.job_manager.builtinDisown(args);
    }

    // ============ Script Manager Access ============

    /// Execute a script file
    pub fn executeScript(self: *const BuiltinContext, filename: []const u8, args: []const []const u8) !ScriptResult {
        const shell_ref = self.shell orelse return error.NoShellContext;
        return try shell_ref.script_manager.executeScript(shell_ref, filename, args);
    }
};

/// Error type for builtin context operations
pub const BuiltinError = error{
    NoShellContext,
    DirStackFull,
    InvalidIndex,
    OutOfMemory,
};
