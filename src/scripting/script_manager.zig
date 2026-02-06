const std = @import("std");
const Shell = @import("../shell.zig").Shell;
const ControlFlowParser = @import("control_flow.zig").ControlFlowParser;
const ControlFlowExecutor = @import("control_flow.zig").ControlFlowExecutor;
const FunctionParser = @import("functions.zig").FunctionParser;

/// Cached script entry
const CachedScript = struct {
    path: []const u8,
    content: []const u8,
    mtime_ns: i96, // File modification time (nanoseconds)
    line_count: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CachedScript) void {
        self.allocator.free(self.path);
        self.allocator.free(self.content);
    }
};

/// Script execution result
pub const ScriptResult = struct {
    exit_code: i32,
    line_executed: usize,
    error_message: ?[]const u8,
};

/// Script Manager - handles script loading, caching, and execution
pub const ScriptManager = struct {
    allocator: std.mem.Allocator,
    cache: std.StringHashMap(CachedScript),
    cache_enabled: bool,
    max_cache_size: usize,
    cache_ttl_ns: i128, // Cache time-to-live in nanoseconds

    const DEFAULT_CACHE_SIZE = 32;
    const DEFAULT_TTL_SECONDS = 300; // 5 minutes

    pub fn init(allocator: std.mem.Allocator) ScriptManager {
        return .{
            .allocator = allocator,
            .cache = std.StringHashMap(CachedScript).init(allocator),
            .cache_enabled = true,
            .max_cache_size = DEFAULT_CACHE_SIZE,
            .cache_ttl_ns = DEFAULT_TTL_SECONDS * std.time.ns_per_s,
        };
    }

    pub fn deinit(self: *ScriptManager) void {
        // Free all cached scripts
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            var cached = entry.value_ptr;
            cached.deinit();
        }
        self.cache.deinit();
    }

    /// Load a script from file (with caching)
    pub fn loadScript(self: *ScriptManager, path: []const u8) ![]const u8 {
        // Check cache first if enabled
        if (self.cache_enabled) {
            if (try self.getFromCache(path)) |content| {
                return content;
            }
        }

        // Load from file
        const content = try self.loadScriptFromFile(path);

        // Add to cache
        if (self.cache_enabled) {
            try self.addToCache(path, content);
        }

        return content;
    }

    /// Load script directly from file (bypassing cache)
    pub fn loadScriptFromFile(self: *ScriptManager, path: []const u8) ![]const u8 {
        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch |err| {
            std.debug.print("Error loading script '{s}': {}\n", .{ path, err });
            return error.ScriptLoadFailed;
        };
        defer file.close(std.Options.debug_io);

        const max_size: usize = 10 * 1024 * 1024;
        const file_size = (file.stat(std.Options.debug_io) catch |err| {
            std.debug.print("Error reading script '{s}': {}\n", .{ path, err });
            return error.ScriptReadFailed;
        }).size;
        const read_size: usize = @min(file_size, max_size);
        const buffer = self.allocator.alloc(u8, read_size) catch |err| {
            std.debug.print("Error allocating for script '{s}': {}\n", .{ path, err });
            return error.ScriptReadFailed;
        };
        errdefer self.allocator.free(buffer);
        var total_read: usize = 0;
        while (total_read < read_size) {
            const n = file.readStreaming(std.Options.debug_io, &.{buffer[total_read..]}) catch |err| {
                std.debug.print("Error reading script '{s}': {}\n", .{ path, err });
                return error.ScriptReadFailed;
            };
            if (n == 0) break;
            total_read += n;
        }
        const content = buffer[0..total_read];

        return content;
    }

    /// Reload a script (invalidate cache and reload)
    pub fn reloadScript(self: *ScriptManager, path: []const u8) ![]const u8 {
        // Remove from cache if present
        if (self.cache.fetchRemove(path)) |entry| {
            var cached = entry.value;
            cached.deinit();
        }

        // Load fresh copy
        return try self.loadScript(path);
    }

    /// Get script from cache if valid
    fn getFromCache(self: *ScriptManager, path: []const u8) !?[]const u8 {
        const cached = self.cache.get(path) orelse return null;

        // Check if cache entry is still valid
        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return null;
        defer file.close(std.Options.debug_io);

        const stat = file.stat(std.Options.debug_io) catch return null;
        const mtime = stat.mtime;

        // Check if file has been modified
        if (mtime.nanoseconds != cached.mtime_ns) {
            // File modified, invalidate cache
            return null;
        }

        // Skip TTL check for simplicity (file modification time is more reliable)

        // Cache hit - return content
        return cached.content;
    }

    /// Add script to cache
    fn addToCache(self: *ScriptManager, path: []const u8, content: []const u8) !void {
        // Check cache size limit
        if (self.cache.count() >= self.max_cache_size) {
            try self.evictOldest();
        }

        // Get file modification time
        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return;
        defer file.close(std.Options.debug_io);
        const stat = file.stat(std.Options.debug_io) catch return;
        const mtime = stat.mtime;

        // Count lines
        var line_count: usize = 0;
        for (content) |c| {
            if (c == '\n') line_count += 1;
        }

        // Create cache entry
        const cached = CachedScript{
            .path = try self.allocator.dupe(u8, path),
            .content = try self.allocator.dupe(u8, content),
            .mtime_ns = mtime.nanoseconds,
            .line_count = line_count,
            .allocator = self.allocator,
        };

        // Store in cache
        try self.cache.put(try self.allocator.dupe(u8, path), cached);
    }

    /// Evict oldest cache entry
    fn evictOldest(self: *ScriptManager) !void {
        var oldest_key: ?[]const u8 = null;
        var oldest_time: i96 = std.math.maxInt(i96);

        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.mtime_ns < oldest_time) {
                oldest_time = entry.value_ptr.mtime_ns;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            if (self.cache.fetchRemove(key)) |entry| {
                var cached = entry.value;
                cached.deinit();
                self.allocator.free(entry.key);
            }
        }
    }

    /// Clear all cached scripts
    pub fn clearCache(self: *ScriptManager) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            var cached = entry.value_ptr;
            cached.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.cache.clearRetainingCapacity();
    }

    /// Get cache statistics
    pub fn getCacheStats(self: *ScriptManager) struct {
        count: usize,
        max_size: usize,
        enabled: bool,
    } {
        return .{
            .count = self.cache.count(),
            .max_size = self.max_cache_size,
            .enabled = self.cache_enabled,
        };
    }

    /// Validate script syntax (basic check)
    pub fn validateScript(self: *ScriptManager, path: []const u8) !bool {
        const content = try self.loadScript(path);
        defer if (!self.cache_enabled) self.allocator.free(content);

        // Basic validation: check for unmatched quotes, braces
        var in_single_quote = false;
        var in_double_quote = false;
        var brace_count: i32 = 0;
        var paren_count: i32 = 0;

        var i: usize = 0;
        while (i < content.len) : (i += 1) {
            const c = content[i];

            // Handle escapes
            if (c == '\\' and i + 1 < content.len) {
                i += 1;
                continue;
            }

            if (!in_double_quote and c == '\'') {
                in_single_quote = !in_single_quote;
            } else if (!in_single_quote and c == '"') {
                in_double_quote = !in_double_quote;
            } else if (!in_single_quote and !in_double_quote) {
                if (c == '{') brace_count += 1;
                if (c == '}') brace_count -= 1;
                if (c == '(') paren_count += 1;
                if (c == ')') paren_count -= 1;
            }
        }

        if (in_single_quote or in_double_quote) {
            std.debug.print("Validation error: Unmatched quotes in '{s}'\n", .{path});
            return false;
        }

        if (brace_count != 0) {
            std.debug.print("Validation error: Unmatched braces in '{s}'\n", .{path});
            return false;
        }

        if (paren_count != 0) {
            std.debug.print("Validation error: Unmatched parentheses in '{s}'\n", .{path});
            return false;
        }

        return true;
    }

    /// Execute script with enhanced error handling
    pub fn executeScript(self: *ScriptManager, shell: *Shell, path: []const u8, args: []const []const u8) anyerror!ScriptResult {
        // Load script (may use cache)
        const content = try self.loadScript(path);
        defer if (!self.cache_enabled) self.allocator.free(content);

        // Validate before execution
        if (!try self.validateScript(path)) {
            return ScriptResult{
                .exit_code = 1,
                .line_executed = 0,
                .error_message = try self.allocator.dupe(u8, "Script validation failed"),
            };
        }

        // Setup positional parameters
        var param_count: usize = 0;
        for (args) |arg| {
            if (param_count >= 64) break;
            const param_copy = try self.allocator.dupe(u8, arg);
            shell.positional_params[param_count] = param_copy;
            param_count += 1;
        }
        shell.positional_params_count = param_count;

        // Set shell name
        const shell_name_copy = try self.allocator.dupe(u8, path);
        shell.shell_name = shell_name_copy;

        // Convert lines to array for control flow processing
        var lines_buffer: [10000][]const u8 = undefined;
        var lines_count: usize = 0;

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            if (lines_count >= lines_buffer.len) return error.TooManyLines;
            lines_buffer[lines_count] = try self.allocator.dupe(u8, line);
            lines_count += 1;
        }
        const lines = lines_buffer[0..lines_count];
        defer {
            for (lines) |line| {
                self.allocator.free(line);
            }
        }

        // Execute with control flow support
        var line_num: usize = 0;
        var parser = ControlFlowParser.init(self.allocator);
        var executor = ControlFlowExecutor.init(shell);
        var func_parser = FunctionParser.init(self.allocator);

        while (line_num < lines.len) : (line_num += 1) {
            shell.current_line = line_num + 1;
            const trimmed = std.mem.trim(u8, lines[line_num], &std.ascii.whitespace);

            // Skip empty lines and comments
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Check for function definition
            // function name { ... } or name() { ... }
            const is_function_keyword = std.mem.startsWith(u8, trimmed, "function ");

            // For name() syntax, check if line contains () followed by { (either same line or next)
            var is_paren_syntax = false;
            if (std.mem.indexOf(u8, trimmed, "()")) |_| {
                // Has (), now check for { on same line or next line
                if (std.mem.indexOf(u8, trimmed, "{") != null) {
                    is_paren_syntax = true;
                } else if (line_num + 1 < lines.len) {
                    const next_trimmed = std.mem.trim(u8, lines[line_num + 1], &std.ascii.whitespace);
                    if (std.mem.startsWith(u8, next_trimmed, "{")) {
                        is_paren_syntax = true;
                    }
                }
            }

            if (is_function_keyword or is_paren_syntax) {
                const result = func_parser.parseFunction(lines, line_num) catch {
                    shell.last_exit_code = 1;
                    shell.executeErrTrap();
                    break;
                };
                // Define the function
                shell.function_manager.defineFunction(result.name, result.body, false) catch {
                    shell.last_exit_code = 1;
                    shell.executeErrTrap();
                    break;
                };
                line_num = result.end;
                continue;
            }

            // Check for control flow keywords
            if (std.mem.startsWith(u8, trimmed, "if ")) {
                var result = parser.parseIf(lines, line_num) catch {
                    shell.last_exit_code = 1;
                    shell.executeErrTrap();
                    break;
                };
                defer result.stmt.deinit();
                shell.last_exit_code = executor.executeIf(&result.stmt) catch 1;
                if (shell.last_exit_code != 0) {
                    shell.executeErrTrap();
                }
                line_num = result.end;
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "while ")) {
                var result = parser.parseWhile(lines, line_num, false) catch {
                    shell.last_exit_code = 1;
                    shell.executeErrTrap();
                    break;
                };
                defer result.loop.deinit();
                shell.last_exit_code = executor.executeWhile(&result.loop) catch 1;
                if (shell.last_exit_code != 0) {
                    shell.executeErrTrap();
                }
                line_num = result.end;
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "until ")) {
                var result = parser.parseWhile(lines, line_num, true) catch {
                    shell.last_exit_code = 1;
                    shell.executeErrTrap();
                    break;
                };
                defer result.loop.deinit();
                shell.last_exit_code = executor.executeWhile(&result.loop) catch 1;
                if (shell.last_exit_code != 0) {
                    shell.executeErrTrap();
                }
                line_num = result.end;
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "for ")) {
                var result = parser.parseFor(lines, line_num) catch {
                    shell.last_exit_code = 1;
                    shell.executeErrTrap();
                    break;
                };
                defer result.loop.deinit();
                shell.last_exit_code = executor.executeFor(&result.loop) catch 1;
                if (shell.last_exit_code != 0) {
                    shell.executeErrTrap();
                }
                line_num = result.end;
                continue;
            }

            // Execute regular command (ignoring errors - exit code set in shell)
            // Note: executeCommand already handles ERR trap execution
            _ = shell.executeCommand(trimmed) catch {};

            // Check if we should exit due to errexit
            if (shell.option_errexit and shell.last_exit_code != 0) {
                shell.current_line = 0;
                return ScriptResult{
                    .exit_code = shell.last_exit_code,
                    .line_executed = line_num,
                    .error_message = null,
                };
            }
        }

        shell.current_line = 0;

        return ScriptResult{
            .exit_code = shell.last_exit_code,
            .line_executed = line_num,
            .error_message = null,
        };
    }
};
