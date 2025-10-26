const std = @import("std");
const types = @import("types.zig");

const ModuleInfo = types.ModuleInfo;
const DetectorFn = types.DetectorFn;

/// Custom module handler
pub const CustomModule = struct {
    name: []const u8,
    command: []const u8,
    format: ?[]const u8,
    icon: ?[]const u8,
    color: ?[]const u8,
    when: ?[]const u8, // Condition to show module (e.g., file pattern)
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, command: []const u8) !CustomModule {
        return .{
            .name = try allocator.dupe(u8, name),
            .command = try allocator.dupe(u8, command),
            .format = null,
            .icon = null,
            .color = null,
            .when = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *const CustomModule) void {
        self.allocator.free(self.name);
        self.allocator.free(self.command);
        if (self.format) |f| self.allocator.free(f);
        if (self.icon) |i| self.allocator.free(i);
        if (self.color) |c| self.allocator.free(c);
        if (self.when) |w| self.allocator.free(w);
    }

    /// Check if module should be shown based on condition
    pub fn shouldShow(self: *const CustomModule, cwd: []const u8) bool {
        if (self.when) |condition| {
            // Simple file pattern check for now
            const path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ cwd, condition }) catch return false;
            defer self.allocator.free(path);

            std.fs.accessAbsolute(path, .{}) catch return false;
            return true;
        }
        return true;
    }

    /// Execute custom module command
    pub fn execute(self: *const CustomModule, _: []const u8) !?ModuleInfo {
        // Parse command into argv
        var argv = std.ArrayList([]const u8).init(self.allocator);
        defer argv.deinit();

        var parts = std.mem.tokenizeAny(u8, self.command, " \t");
        while (parts.next()) |part| {
            try argv.append(part);
        }

        if (argv.items.len == 0) return null;

        // Execute command
        var child = std.process.Child.init(argv.items, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        child.spawn() catch return null;

        const output = child.stdout.?.readToEndAlloc(self.allocator, 4096) catch return null;
        defer self.allocator.free(output);

        const status = child.wait() catch return null;
        if (status != .Exited or status.Exited != 0) return null;

        const trimmed = std.mem.trim(u8, output, &std.ascii.whitespace);
        if (trimmed.len == 0) return null;

        var info = ModuleInfo.init(self.name);
        info.version = try self.allocator.dupe(u8, trimmed);
        info.icon = self.icon;
        info.color = self.color;

        return info;
    }
};

/// Format string parser and renderer
pub const FormatString = struct {
    template: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, template: []const u8) !FormatString {
        return .{
            .template = try allocator.dupe(u8, template),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *const FormatString) void {
        self.allocator.free(self.template);
    }

    /// Render format string with module info
    /// Supports: {symbol}, {version}, {name}
    pub fn render(self: *const FormatString, info: *const ModuleInfo) ![]const u8 {
        var result: std.ArrayList(u8) = .{
            .items = &[_]u8{},
            .capacity = 0,
        };
        defer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < self.template.len) {
            if (self.template[i] == '{') {
                // Find closing brace
                const start = i + 1;
                var end = start;
                while (end < self.template.len and self.template[end] != '}') : (end += 1) {}

                if (end < self.template.len) {
                    const placeholder = self.template[start..end];

                    if (std.mem.eql(u8, placeholder, "symbol")) {
                        if (info.icon) |icon| {
                            try result.appendSlice(self.allocator, icon);
                        }
                    } else if (std.mem.eql(u8, placeholder, "version")) {
                        if (info.version) |version| {
                            try result.appendSlice(self.allocator, version);
                        }
                    } else if (std.mem.eql(u8, placeholder, "name")) {
                        try result.appendSlice(self.allocator, info.name);
                    }

                    i = end + 1;
                } else {
                    // No closing brace
                    try result.append(self.allocator, '{');
                    i += 1;
                }
            } else {
                try result.append(self.allocator, self.template[i]);
                i += 1;
            }
        }

        return try result.toOwnedSlice(self.allocator);
    }
};

/// Custom module registry
pub const CustomModuleRegistry = struct {
    modules: std.StringHashMap(CustomModule),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CustomModuleRegistry {
        return .{
            .modules = std.StringHashMap(CustomModule).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CustomModuleRegistry) void {
        var iter = self.modules.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.modules.deinit();
    }

    /// Register a custom module
    pub fn register(self: *CustomModuleRegistry, module: CustomModule) !void {
        const key = try self.allocator.dupe(u8, module.name);
        try self.modules.put(key, module);
    }

    /// Get a custom module detector function
    pub fn getDetector(self: *CustomModuleRegistry, name: []const u8) ?DetectorFn {
        if (self.modules.getPtr(name)) |module| {
            const Wrapper = struct {
                fn detect(allocator: std.mem.Allocator, cwd: []const u8) !?ModuleInfo {
                    // This is a bit tricky - we need access to the module
                    // In practice, you'd pass the module pointer through userdata
                    _ = allocator;
                    _ = cwd;
                    return null;
                }
            };
            _ = module;
            return Wrapper.detect;
        }
        return null;
    }

    /// Detect a custom module
    pub fn detect(self: *CustomModuleRegistry, name: []const u8, cwd: []const u8) !?ModuleInfo {
        const module = self.modules.get(name) orelse return null;

        if (!module.shouldShow(cwd)) return null;

        return try module.execute(cwd);
    }
};
