const std = @import("std");
const types = @import("types.zig");

const ModuleInfo = types.ModuleInfo;
const DetectorFn = types.DetectorFn;
const ModuleConfig = types.ModuleConfig;

/// Module cache entry
const CacheEntry = struct {
    info: ModuleInfo,
    timestamp: i64,
};

/// Module registry with caching
pub const ModuleRegistry = struct {
    allocator: std.mem.Allocator,
    detectors: std.StringHashMap(DetectorFn),
    configs: std.StringHashMap(ModuleConfig),
    cache: std.StringHashMap(CacheEntry),
    cache_ttl_seconds: i64,

    pub fn init(allocator: std.mem.Allocator) ModuleRegistry {
        return .{
            .allocator = allocator,
            .detectors = std.StringHashMap(DetectorFn).init(allocator),
            .configs = std.StringHashMap(ModuleConfig).init(allocator),
            .cache = std.StringHashMap(CacheEntry).init(allocator),
            .cache_ttl_seconds = 60, // Cache for 60 seconds
        };
    }

    pub fn deinit(self: *ModuleRegistry) void {
        // Free detector keys
        var detector_iter = self.detectors.iterator();
        while (detector_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.detectors.deinit();

        // Free config keys
        var config_iter = self.configs.iterator();
        while (config_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.configs.deinit();

        // Free cache
        var cache_iter = self.cache.iterator();
        while (cache_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var info = entry.value_ptr.info;
            info.deinit(self.allocator);
        }
        self.cache.deinit();
    }

    /// Register a module detector
    pub fn register(self: *ModuleRegistry, name: []const u8, detector: DetectorFn) !void {
        const key = try self.allocator.dupe(u8, name);
        try self.detectors.put(key, detector);

        // Initialize default config
        const config_key = try self.allocator.dupe(u8, name);
        try self.configs.put(config_key, ModuleConfig.initDefault());
    }

    /// Configure a module
    pub fn configure(self: *ModuleRegistry, name: []const u8, config: ModuleConfig) !void {
        if (self.configs.getPtr(name)) |existing| {
            existing.* = config;
        } else {
            const key = try self.allocator.dupe(u8, name);
            try self.configs.put(key, config);
        }
    }

    /// Enable/disable a module
    pub fn setEnabled(self: *ModuleRegistry, name: []const u8, enabled: bool) !void {
        if (self.configs.getPtr(name)) |config| {
            config.enabled = enabled;
        } else {
            var config = ModuleConfig.initDefault();
            config.enabled = enabled;
            const key = try self.allocator.dupe(u8, name);
            try self.configs.put(key, config);
        }
    }

    /// Detect a module (with caching)
    pub fn detect(self: *ModuleRegistry, name: []const u8, cwd: []const u8) !?ModuleInfo {
        // Check if module is enabled
        const config = self.configs.get(name) orelse ModuleConfig.initDefault();
        if (!config.enabled) {
            return null;
        }

        // Check cache
        const now = std.time.timestamp();
        if (self.cache.get(name)) |entry| {
            if (now - entry.timestamp < self.cache_ttl_seconds) {
                // Return cached copy (need to dupe version string)
                var cached_info = ModuleInfo.init(entry.info.name);
                cached_info.enabled = entry.info.enabled;
                cached_info.icon = entry.info.icon;
                cached_info.color = entry.info.color;
                if (entry.info.version) |v| {
                    cached_info.version = try self.allocator.dupe(u8, v);
                }
                return cached_info;
            }
        }

        // Detect module
        const detector = self.detectors.get(name) orelse return null;
        const info = try detector(self.allocator, cwd) orelse return null;

        // Apply config overrides
        var final_info = info;
        if (config.icon) |icon| {
            final_info.icon = icon;
        }
        if (config.color) |color| {
            final_info.color = color;
        }

        // Cache result (create a copy for cache)
        var cache_info = ModuleInfo.init(final_info.name);
        cache_info.enabled = final_info.enabled;
        cache_info.icon = final_info.icon;
        cache_info.color = final_info.color;
        if (final_info.version) |v| {
            cache_info.version = try self.allocator.dupe(u8, v);
        }

        const cache_key = try self.allocator.dupe(u8, name);
        try self.cache.put(cache_key, .{
            .info = cache_info,
            .timestamp = now,
        });

        return final_info;
    }

    /// Clear cache
    pub fn clearCache(self: *ModuleRegistry) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var info = entry.value_ptr.info;
            info.deinit(self.allocator);
        }
        self.cache.clearRetainingCapacity();
    }

    /// Clear cache for a specific module
    pub fn clearCacheFor(self: *ModuleRegistry, name: []const u8) void {
        if (self.cache.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            var info = kv.value.info;
            info.deinit(self.allocator);
        }
    }

    /// Render module to string
    pub fn render(self: *ModuleRegistry, info: *const ModuleInfo, config: ?ModuleConfig) ![]const u8 {
        const cfg = config orelse ModuleConfig.initDefault();

        // If format string is provided, use it
        if (cfg.format) |format_str| {
            return try self.renderWithFormat(info, format_str);
        }

        var result: std.ArrayList(u8) = .{
            .items = &[_]u8{},
            .capacity = 0,
        };
        defer result.deinit(self.allocator);

        // Icon
        if (info.icon) |icon| {
            try result.appendSlice(self.allocator, icon);
            try result.append(self.allocator, ' ');
        }

        // Version
        if (cfg.show_version) {
            if (info.version) |version| {
                try result.appendSlice(self.allocator, version);
            }
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// Render module with custom format string
    fn renderWithFormat(self: *ModuleRegistry, info: *const ModuleInfo, format_str: []const u8) ![]const u8 {
        var result: std.ArrayList(u8) = .{
            .items = &[_]u8{},
            .capacity = 0,
        };
        defer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < format_str.len) {
            if (format_str[i] == '{') {
                const start = i + 1;
                var end = start;
                while (end < format_str.len and format_str[end] != '}') : (end += 1) {}

                if (end < format_str.len) {
                    const placeholder = format_str[start..end];

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
                    try result.append(self.allocator, '{');
                    i += 1;
                }
            } else {
                try result.append(self.allocator, format_str[i]);
                i += 1;
            }
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// Detect all registered modules
    pub fn detectAll(self: *ModuleRegistry, cwd: []const u8) !std.ArrayList(ModuleInfo) {
        var modules: std.ArrayList(ModuleInfo) = .{
            .items = &[_]ModuleInfo{},
            .capacity = 0,
        };

        var iter = self.detectors.iterator();
        while (iter.next()) |entry| {
            const name = entry.key_ptr.*;
            if (try self.detect(name, cwd)) |info| {
                try modules.append(self.allocator, info);
            }
        }

        return modules;
    }

    /// Render all detected modules
    pub fn renderAll(self: *ModuleRegistry, cwd: []const u8) ![]const u8 {
        var modules = try self.detectAll(cwd);
        defer {
            for (modules.items) |*m| {
                m.deinit(self.allocator);
            }
            modules.deinit(self.allocator);
        }

        if (modules.items.len == 0) {
            return try self.allocator.dupe(u8, "");
        }

        var result: std.ArrayList(u8) = .{
            .items = &[_]u8{},
            .capacity = 0,
        };
        defer result.deinit(self.allocator);

        for (modules.items, 0..) |*info, i| {
            const config = self.configs.get(info.name);
            const rendered = try self.render(info, config);
            defer self.allocator.free(rendered);

            try result.appendSlice(self.allocator, rendered);

            if (i < modules.items.len - 1) {
                try result.append(self.allocator, ' ');
            }
        }

        return try result.toOwnedSlice(self.allocator);
    }
};
