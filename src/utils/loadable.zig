const std = @import("std");
const builtin = @import("builtin");

/// Function signature for loadable builtins
/// argc: number of arguments (including command name)
/// argv: null-terminated array of null-terminated argument strings
/// Returns: exit code (0 for success)
pub const BuiltinFn = *const fn (argc: c_int, argv: [*]const [*:0]const u8) callconv(.c) c_int;

/// Initialization function signature (optional)
/// Called when the builtin is loaded
pub const InitFn = *const fn () callconv(.c) c_int;

/// Finalization function signature (optional)
/// Called when the builtin is unloaded
pub const FiniFn = *const fn () callconv(.c) void;

/// Loaded builtin information
pub const LoadedBuiltin = struct {
    name: []const u8,
    path: []const u8,
    handle: ?*anyopaque,
    builtin_fn: ?BuiltinFn,
    fini_fn: ?FiniFn,
    enabled: bool,
};

/// Loadable builtins registry
pub const LoadableBuiltins = struct {
    allocator: std.mem.Allocator,
    builtins: std.StringHashMap(LoadedBuiltin),

    pub fn init(allocator: std.mem.Allocator) LoadableBuiltins {
        return .{
            .allocator = allocator,
            .builtins = std.StringHashMap(LoadedBuiltin).init(allocator),
        };
    }

    pub fn deinit(self: *LoadableBuiltins) void {
        var iter = self.builtins.iterator();
        while (iter.next()) |entry| {
            const info = entry.value_ptr.*;
            // Call fini function if available
            if (info.fini_fn) |fini| {
                fini();
            }
            // Close handle
            if (info.handle) |handle| {
                self.closeLibrary(handle);
            }
            // Free strings
            self.allocator.free(info.name);
            self.allocator.free(info.path);
        }
        self.builtins.deinit();
    }

    /// Load a builtin from a shared library
    /// The library should export:
    ///   - int <name>_builtin(int argc, char **argv) - the builtin function
    ///   - int <name>_builtin_init(void) - optional initialization
    ///   - void <name>_builtin_fini(void) - optional cleanup
    pub fn load(self: *LoadableBuiltins, name: []const u8, path: []const u8) !void {
        // Check if already loaded
        if (self.builtins.contains(name)) {
            return error.AlreadyLoaded;
        }

        // Open the shared library
        const handle = self.openLibrary(path) orelse {
            return error.LoadFailed;
        };
        errdefer self.closeLibrary(handle);

        // Look up the builtin function
        var fn_name_buf: [256]u8 = undefined;
        const fn_name = std.fmt.bufPrint(&fn_name_buf, "{s}_builtin", .{name}) catch {
            return error.NameTooLong;
        };
        fn_name_buf[fn_name.len] = 0;

        const builtin_fn = self.lookupSymbol(BuiltinFn, handle, fn_name_buf[0..fn_name.len :0]) orelse {
            return error.SymbolNotFound;
        };

        // Look up optional init function
        const init_fn_name = std.fmt.bufPrint(&fn_name_buf, "{s}_builtin_init", .{name}) catch null;
        if (init_fn_name) |init_name| {
            fn_name_buf[init_name.len] = 0;
            if (self.lookupSymbol(InitFn, handle, fn_name_buf[0..init_name.len :0])) |init_fn| {
                const result = init_fn();
                if (result != 0) {
                    return error.InitFailed;
                }
            }
        }

        // Look up optional fini function
        const fini_name = std.fmt.bufPrint(&fn_name_buf, "{s}_builtin_fini", .{name}) catch null;
        var fini_fn: ?FiniFn = null;
        if (fini_name) |f_name| {
            fn_name_buf[f_name.len] = 0;
            fini_fn = self.lookupSymbol(FiniFn, handle, fn_name_buf[0..f_name.len :0]);
        }

        // Store the loaded builtin
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        try self.builtins.put(name_copy, .{
            .name = name_copy,
            .path = path_copy,
            .handle = handle,
            .builtin_fn = builtin_fn,
            .fini_fn = fini_fn,
            .enabled = true,
        });
    }

    /// Unload a builtin
    pub fn unload(self: *LoadableBuiltins, name: []const u8) !void {
        if (self.builtins.fetchRemove(name)) |kv| {
            const info = kv.value;
            // Call fini function if available
            if (info.fini_fn) |fini| {
                fini();
            }
            // Close handle
            if (info.handle) |handle| {
                self.closeLibrary(handle);
            }
            // Free strings
            self.allocator.free(info.name);
            self.allocator.free(info.path);
        } else {
            return error.NotLoaded;
        }
    }

    /// Enable a loaded builtin
    pub fn enable(self: *LoadableBuiltins, name: []const u8) !void {
        if (self.builtins.getPtr(name)) |info| {
            info.enabled = true;
        } else {
            return error.NotLoaded;
        }
    }

    /// Disable a loaded builtin (without unloading)
    pub fn disable(self: *LoadableBuiltins, name: []const u8) !void {
        if (self.builtins.getPtr(name)) |info| {
            info.enabled = false;
        } else {
            return error.NotLoaded;
        }
    }

    /// Check if a builtin is loaded and enabled
    pub fn isEnabled(self: *LoadableBuiltins, name: []const u8) bool {
        if (self.builtins.get(name)) |info| {
            return info.enabled;
        }
        return false;
    }

    /// Execute a loadable builtin
    pub fn execute(self: *LoadableBuiltins, allocator: std.mem.Allocator, name: []const u8, args: []const []const u8) !i32 {
        const info = self.builtins.get(name) orelse return error.NotLoaded;
        if (!info.enabled) return error.Disabled;
        const builtin_fn = info.builtin_fn orelse return error.NoFunction;

        // Convert args to C format
        // Allocate argv array (name + args + null terminator)
        const argc: c_int = @intCast(args.len + 1);
        const argv = try allocator.alloc(?[*:0]const u8, @intCast(argc + 1));
        defer allocator.free(argv);

        // First arg is the command name (null-terminated)
        const name_z = try allocator.allocSentinel(u8, name.len, 0);
        defer allocator.free(name_z);
        @memcpy(name_z, name);
        argv[0] = name_z.ptr;

        // Copy remaining args with null terminators
        var arg_copies = try allocator.alloc([*:0]const u8, args.len);
        defer {
            for (arg_copies) |a| {
                allocator.free(std.mem.span(a));
            }
            allocator.free(arg_copies);
        }

        for (args, 0..) |arg, i| {
            const arg_z = try allocator.allocSentinel(u8, arg.len, 0);
            @memcpy(arg_z, arg);
            arg_copies[i] = arg_z.ptr;
            argv[i + 1] = arg_z.ptr;
        }
        argv[@intCast(argc)] = null; // null terminator

        // Call the builtin function - need to cast argv
        const argv_ptr: [*]const [*:0]const u8 = @ptrCast(argv.ptr);
        return builtin_fn(argc, argv_ptr);
    }

    /// List all loaded builtins
    pub fn list(self: *LoadableBuiltins) std.StringHashMap(LoadedBuiltin).Iterator {
        return self.builtins.iterator();
    }

    /// Platform-specific library loading
    fn openLibrary(self: *LoadableBuiltins, path: []const u8) ?*anyopaque {
        _ = self;
        if (builtin.os.tag == .windows) {
            // Windows: LoadLibrary
            @compileError("Loadable builtins not yet supported on Windows");
        } else {
            // POSIX: dlopen
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (path.len >= path_buf.len) return null;
            @memcpy(path_buf[0..path.len], path);
            path_buf[path.len] = 0;
            // Use LAZY and LOCAL mode for loading
            const mode = std.c.RTLD{ .LAZY = true, .LOCAL = true };
            return std.c.dlopen(@ptrCast(&path_buf), mode);
        }
    }

    fn closeLibrary(self: *LoadableBuiltins, handle: *anyopaque) void {
        _ = self;
        if (builtin.os.tag == .windows) {
            @compileError("Loadable builtins not yet supported on Windows");
        } else {
            _ = std.c.dlclose(handle);
        }
    }

    fn lookupSymbol(self: *LoadableBuiltins, comptime T: type, handle: *anyopaque, name: [:0]const u8) ?T {
        _ = self;
        if (builtin.os.tag == .windows) {
            @compileError("Loadable builtins not yet supported on Windows");
        } else {
            const sym = std.c.dlsym(handle, name.ptr);
            if (sym == null) return null;
            return @ptrCast(@alignCast(sym));
        }
    }
};
