const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const shell_module = @import("shell_module.zig");
const overlay = @import("overlay.zig");
const stdlib_loader = @import("../stdlib/loader.zig");

const ShellModule = shell_module.ShellModule;
const ModuleStore = shell_module.ModuleStore;
const OverlayStack = overlay.OverlayStack;

/// Result of resolving a `use` statement.
pub const ImportResult = struct {
    /// Commands that were imported (name -> body lines).
    /// Caller owns both the slice and the duped strings within.
    imported_commands: std.ArrayList(ImportedCommand),

    /// Variables that were imported (name -> value).
    imported_variables: std.ArrayList(ImportedVariable),

    /// The name of the source module.
    module_name: []const u8,

    pub const ImportedCommand = struct {
        name: []const u8,
        body_lines: std.ArrayList([]const u8),
    };

    pub const ImportedVariable = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn deinit(self: *ImportResult, allocator: std.mem.Allocator) void {
        for (self.imported_commands.items) |*cmd| {
            allocator.free(cmd.name);
            for (cmd.body_lines.items) |line| {
                allocator.free(line);
            }
            cmd.body_lines.deinit(allocator);
        }
        self.imported_commands.deinit(allocator);

        for (self.imported_variables.items) |*v| {
            allocator.free(v.name);
            allocator.free(v.value);
        }
        self.imported_variables.deinit(allocator);

        allocator.free(self.module_name);
    }
};

/// Errors that can occur during import resolution.
pub const ImportError = error{
    ModuleNotFound,
    CommandNotFound,
    VariableNotFound,
    InvalidImportSyntax,
    CircularImport,
    OutOfMemory,
};

/// Handles `use <module>` and `use <module> [item1, item2]` resolution.
///
/// The ImportResolver takes a ModuleStore (where modules are registered)
/// and resolves import requests into ImportResults that can then be applied
/// to an OverlayStack.
pub const ImportResolver = struct {
    /// Reference to the global module store.
    store: *const ModuleStore,

    /// Tracks modules currently being imported to detect circular imports.
    importing: std.StringHashMap(void),

    /// Module search paths for file-based module loading.
    search_paths: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, store: *const ModuleStore) ImportResolver {
        return .{
            .store = store,
            .importing = std.StringHashMap(void).empty,
            .search_paths = .{
                .items = &[_][]const u8{},
                .capacity = 0,
            },
        };
    }

    pub fn deinit(self: *ImportResolver, allocator: std.mem.Allocator) void {
        var iter = self.importing.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.importing.deinit(allocator);

        for (self.search_paths.items) |p| {
            allocator.free(p);
        }
        self.search_paths.deinit(allocator);
    }

    /// Add a directory to the module search path.
    /// The path string is duped.
    pub fn addSearchPath(self: *ImportResolver, allocator: std.mem.Allocator, path: []const u8) !void {
        const duped = try allocator.dupe(u8, path);
        try self.search_paths.append(allocator, duped);
    }

    /// Resolve `use <module_name>` -- import everything from the module.
    ///
    /// Returns an ImportResult containing all commands and variables
    /// exported by the module. The caller is responsible for applying
    /// the result to an OverlayStack and then freeing the result.
    pub fn resolveAll(self: *ImportResolver, allocator: std.mem.Allocator, module_name: []const u8) ImportError!ImportResult {
        // Check for circular import.
        if (self.importing.contains(module_name)) {
            return ImportError.CircularImport;
        }

        const module = self.store.get(module_name) orelse {
            return ImportError.ModuleNotFound;
        };

        // Mark as importing.
        const mark_key = allocator.dupe(u8, module_name) catch return ImportError.OutOfMemory;
        self.importing.put(allocator, mark_key, {}) catch return ImportError.OutOfMemory;
        defer {
            if (self.importing.fetchRemove(module_name)) |removed| {
                allocator.free(removed.key);
            }
        }

        var result = ImportResult{
            .imported_commands = .{
                .items = &[_]ImportResult.ImportedCommand{},
                .capacity = 0,
            },
            .imported_variables = .{
                .items = &[_]ImportResult.ImportedVariable{},
                .capacity = 0,
            },
            .module_name = allocator.dupe(u8, module_name) catch return ImportError.OutOfMemory,
        };

        // Import all commands.
        var cmd_iter = module.commands.iterator();
        while (cmd_iter.next()) |entry| {
            var body_lines: std.ArrayList([]const u8) = .{
                .items = &[_][]const u8{},
                .capacity = 0,
            };
            for (entry.value_ptr.items) |line| {
                const duped = allocator.dupe(u8, line) catch return ImportError.OutOfMemory;
                body_lines.append(allocator, duped) catch return ImportError.OutOfMemory;
            }

            const cmd = ImportResult.ImportedCommand{
                .name = allocator.dupe(u8, entry.key_ptr.*) catch return ImportError.OutOfMemory,
                .body_lines = body_lines,
            };
            result.imported_commands.append(allocator, cmd) catch return ImportError.OutOfMemory;
        }

        // Import all variables.
        var var_iter = module.variables.iterator();
        while (var_iter.next()) |entry| {
            const v = ImportResult.ImportedVariable{
                .name = allocator.dupe(u8, entry.key_ptr.*) catch return ImportError.OutOfMemory,
                .value = allocator.dupe(u8, entry.value_ptr.*) catch return ImportError.OutOfMemory,
            };
            result.imported_variables.append(allocator, v) catch return ImportError.OutOfMemory;
        }

        return result;
    }

    /// Resolve `use <module_name> [item1, item2]` -- selective import.
    ///
    /// `selected_names` is a slice of names to import. Each name is looked
    /// up first as a command, then as a variable. If a name is found as
    /// neither, an error is returned.
    pub fn resolveSelective(
        self: *ImportResolver,
        allocator: std.mem.Allocator,
        module_name: []const u8,
        selected_names: []const []const u8,
    ) ImportError!ImportResult {
        // Check for circular import.
        if (self.importing.contains(module_name)) {
            return ImportError.CircularImport;
        }

        const module = self.store.get(module_name) orelse {
            return ImportError.ModuleNotFound;
        };

        // Mark as importing.
        const mark_key = allocator.dupe(u8, module_name) catch return ImportError.OutOfMemory;
        self.importing.put(allocator, mark_key, {}) catch return ImportError.OutOfMemory;
        defer {
            if (self.importing.fetchRemove(module_name)) |removed| {
                allocator.free(removed.key);
            }
        }

        var result = ImportResult{
            .imported_commands = .{
                .items = &[_]ImportResult.ImportedCommand{},
                .capacity = 0,
            },
            .imported_variables = .{
                .items = &[_]ImportResult.ImportedVariable{},
                .capacity = 0,
            },
            .module_name = allocator.dupe(u8, module_name) catch return ImportError.OutOfMemory,
        };

        for (selected_names) |name| {
            // Try as a command first.
            if (module.getCommand(name)) |body| {
                var body_lines: std.ArrayList([]const u8) = .{
                    .items = &[_][]const u8{},
                    .capacity = 0,
                };
                for (body) |line| {
                    const duped = allocator.dupe(u8, line) catch return ImportError.OutOfMemory;
                    body_lines.append(allocator, duped) catch return ImportError.OutOfMemory;
                }

                const cmd = ImportResult.ImportedCommand{
                    .name = allocator.dupe(u8, name) catch return ImportError.OutOfMemory,
                    .body_lines = body_lines,
                };
                result.imported_commands.append(allocator, cmd) catch return ImportError.OutOfMemory;
                continue;
            }

            // Try as a variable.
            if (module.getVariable(name)) |value| {
                const v = ImportResult.ImportedVariable{
                    .name = allocator.dupe(u8, name) catch return ImportError.OutOfMemory,
                    .value = allocator.dupe(u8, value) catch return ImportError.OutOfMemory,
                };
                result.imported_variables.append(allocator, v) catch return ImportError.OutOfMemory;
                continue;
            }

            // Name not found in the module -- clean up and return error.
            result.deinit(allocator);
            return ImportError.CommandNotFound;
        }

        return result;
    }

    /// Convenience: resolve an import and immediately apply it to an
    /// overlay stack. A new overlay layer is pushed with the module name,
    /// and all imported commands and variables are placed into it.
    pub fn resolveAndApply(
        self: *ImportResolver,
        allocator: std.mem.Allocator,
        module_name: []const u8,
        selected_names: ?[]const []const u8,
        stack: *OverlayStack,
    ) ImportError!void {
        var result = if (selected_names) |names|
            try self.resolveSelective(allocator, module_name, names)
        else
            try self.resolveAll(allocator, module_name);
        defer result.deinit(allocator);

        // Push a new overlay layer for this import.
        stack.push(allocator, module_name) catch return ImportError.OutOfMemory;

        // Apply commands.
        for (result.imported_commands.items) |*cmd| {
            stack.setCommand(allocator, cmd.name, cmd.body_lines.items) catch return ImportError.OutOfMemory;
        }

        // Apply variables.
        for (result.imported_variables.items) |*v| {
            stack.setEnvVar(allocator, v.name, v.value) catch return ImportError.OutOfMemory;
        }
    }

    /// Check if a module is available in the embedded stdlib.
    /// Returns the script content if found, null otherwise.
    pub fn getStdlibScript(_: *const ImportResolver, module_name: []const u8) ?[]const u8 {
        return stdlib_loader.getScript(module_name);
    }

    /// List all available stdlib module names.
    pub fn listStdlibModules(_: *const ImportResolver) []const []const u8 {
        return stdlib_loader.listModules();
    }

    /// Resolve a module file path from search paths.
    /// Looks for `<name>.den` in each search path directory.
    /// Returns the full path (caller owns), or null if not found.
    pub fn resolveModulePath(self: *const ImportResolver, allocator: std.mem.Allocator, module_name: []const u8) !?[]const u8 {
        for (self.search_paths.items) |dir| {
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}.den", .{ dir, module_name });

            std.Io.Dir.accessAbsolute(std.Options.debug_io, path, .{}) catch {
                allocator.free(path);
                continue;
            };
            return path;
        }
        return null;
    }
};

/// Parse a selective import list from a string like "[add, sub]".
/// Returns a slice of name strings. Caller owns the returned slice and
/// each string within.
pub fn parseImportList(allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);

    // Must start with '[' and end with ']'.
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
        return error.InvalidImportSyntax;
    }

    const inner = trimmed[1 .. trimmed.len - 1];

    var names: std.ArrayList([]const u8) = .{
        .items = &[_][]const u8{},
        .capacity = 0,
    };
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var parts = std.mem.splitScalar(u8, inner, ',');
    while (parts.next()) |part| {
        const name = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (name.len == 0) continue;
        const duped = try allocator.dupe(u8, name);
        try names.append(allocator, duped);
    }

    return try names.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseImportList basic" {
    const allocator = std.testing.allocator;

    const names = try parseImportList(allocator, "[add, sub]");
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("add", names[0]);
    try std.testing.expectEqualStrings("sub", names[1]);
}

test "parseImportList single item" {
    const allocator = std.testing.allocator;

    const names = try parseImportList(allocator, "[add]");
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("add", names[0]);
}

test "parseImportList with extra whitespace" {
    const allocator = std.testing.allocator;

    const names = try parseImportList(allocator, "[ add , sub , mul ]");
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqualStrings("add", names[0]);
    try std.testing.expectEqualStrings("sub", names[1]);
    try std.testing.expectEqualStrings("mul", names[2]);
}

test "parseImportList invalid syntax" {
    const allocator = std.testing.allocator;

    const result = parseImportList(allocator, "add, sub");
    try std.testing.expectError(error.InvalidImportSyntax, result);
}

test "ImportResolver resolveAll" {
    const allocator = std.testing.allocator;

    var store = ModuleStore.init();
    defer store.deinit(allocator);

    var module = try ShellModule.init(allocator, "math");
    try module.defineCommand(allocator, "add", &[_][]const u8{"expr $a + $b"});
    try module.defineCommand(allocator, "sub", &[_][]const u8{"expr $a - $b"});
    try module.exportVariable(allocator, "PI", "3.14");
    module.markLoaded();
    try store.register(allocator, module);

    var resolver = ImportResolver.init(allocator, &store);
    defer resolver.deinit(allocator);

    var result = try resolver.resolveAll(allocator, "math");
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("math", result.module_name);
    try std.testing.expectEqual(@as(usize, 2), result.imported_commands.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.imported_variables.items.len);
}

test "ImportResolver resolveSelective" {
    const allocator = std.testing.allocator;

    var store = ModuleStore.init();
    defer store.deinit(allocator);

    var module = try ShellModule.init(allocator, "math");
    try module.defineCommand(allocator, "add", &[_][]const u8{"expr $a + $b"});
    try module.defineCommand(allocator, "sub", &[_][]const u8{"expr $a - $b"});
    try module.exportVariable(allocator, "PI", "3.14");
    module.markLoaded();
    try store.register(allocator, module);

    var resolver = ImportResolver.init(allocator, &store);
    defer resolver.deinit(allocator);

    const selected = &[_][]const u8{"add"};
    var result = try resolver.resolveSelective(allocator, "math", selected);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.imported_commands.items.len);
    try std.testing.expectEqualStrings("add", result.imported_commands.items[0].name);
}

test "ImportResolver module not found" {
    const allocator = std.testing.allocator;

    var store = ModuleStore.init();
    defer store.deinit(allocator);

    var resolver = ImportResolver.init(allocator, &store);
    defer resolver.deinit(allocator);

    const result = resolver.resolveAll(allocator, "nonexistent");
    try std.testing.expectError(ImportError.ModuleNotFound, result);
}

test "ImportResolver resolveAndApply" {
    const allocator = std.testing.allocator;

    var store = ModuleStore.init();
    defer store.deinit(allocator);

    var module = try ShellModule.init(allocator, "math");
    try module.defineCommand(allocator, "add", &[_][]const u8{"expr $a + $b"});
    try module.exportVariable(allocator, "PI", "3.14");
    module.markLoaded();
    try store.register(allocator, module);

    var resolver = ImportResolver.init(allocator, &store);
    defer resolver.deinit(allocator);

    var stack = try OverlayStack.init(allocator);
    defer stack.deinit(allocator);

    try resolver.resolveAndApply(allocator, "math", null, &stack);

    // Check the overlay stack has the imported items.
    try std.testing.expectEqual(@as(usize, 2), stack.depth()); // global + math
    try std.testing.expect(stack.getCommand("add") != null);
    try std.testing.expectEqualStrings("3.14", stack.getEnvVar("PI").?);
}

test "ImportResolver selective resolveAndApply" {
    const allocator = std.testing.allocator;

    var store = ModuleStore.init();
    defer store.deinit(allocator);

    var module = try ShellModule.init(allocator, "math");
    try module.defineCommand(allocator, "add", &[_][]const u8{"expr $a + $b"});
    try module.defineCommand(allocator, "sub", &[_][]const u8{"expr $a - $b"});
    module.markLoaded();
    try store.register(allocator, module);

    var resolver = ImportResolver.init(allocator, &store);
    defer resolver.deinit(allocator);

    var stack = try OverlayStack.init(allocator);
    defer stack.deinit(allocator);

    const selected = &[_][]const u8{"add"};
    try resolver.resolveAndApply(allocator, "math", selected, &stack);

    try std.testing.expect(stack.getCommand("add") != null);
    try std.testing.expect(stack.getCommand("sub") == null);
}
