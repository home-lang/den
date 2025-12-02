// Shell-specific memory pools for common objects
// Reduces allocation overhead for frequently used structures
const std = @import("std");
const types = @import("../types/mod.zig");

/// Pool sizes tuned for typical shell usage
pub const PoolConfig = struct {
    /// Max commands in a single chain (e.g., `a && b && c | d`)
    max_commands: usize = 32,
    /// Max arguments per command
    max_args: usize = 64,
    /// Max redirections per command
    max_redirections: usize = 8,
    /// String buffer size for small strings
    small_string_size: usize = 256,
    /// Number of small string buffers to pool
    small_string_count: usize = 64,
};

/// Pooled command builder - reduces allocations for command parsing
pub const CommandPool = struct {
    allocator: std.mem.Allocator,
    config: PoolConfig,

    // Pre-allocated buffers
    commands_buffer: []types.ParsedCommand,
    args_buffer: [][]const u8,
    redirections_buffer: []types.Redirection,
    operators_buffer: []types.Operator,

    // String pool for small strings
    string_pool: StringPool,

    // Usage tracking
    commands_used: usize = 0,
    args_used: usize = 0,
    redirections_used: usize = 0,
    operators_used: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: PoolConfig) !CommandPool {
        return .{
            .allocator = allocator,
            .config = config,
            .commands_buffer = try allocator.alloc(types.ParsedCommand, config.max_commands),
            .args_buffer = try allocator.alloc([]const u8, config.max_commands * config.max_args),
            .redirections_buffer = try allocator.alloc(types.Redirection, config.max_commands * config.max_redirections),
            .operators_buffer = try allocator.alloc(types.Operator, config.max_commands),
            .string_pool = try StringPool.init(allocator, config.small_string_count, config.small_string_size),
        };
    }

    pub fn deinit(self: *CommandPool) void {
        self.allocator.free(self.commands_buffer);
        self.allocator.free(self.args_buffer);
        self.allocator.free(self.redirections_buffer);
        self.allocator.free(self.operators_buffer);
        self.string_pool.deinit();
    }

    /// Reset pool for reuse (call after each command execution)
    pub fn reset(self: *CommandPool) void {
        self.commands_used = 0;
        self.args_used = 0;
        self.redirections_used = 0;
        self.operators_used = 0;
        self.string_pool.reset();
    }

    /// Allocate a command slot
    pub fn allocCommand(self: *CommandPool) !*types.ParsedCommand {
        if (self.commands_used >= self.config.max_commands) {
            return error.CommandPoolExhausted;
        }
        const cmd = &self.commands_buffer[self.commands_used];
        self.commands_used += 1;
        return cmd;
    }

    /// Allocate argument slots
    pub fn allocArgs(self: *CommandPool, count: usize) ![][]const u8 {
        if (self.args_used + count > self.args_buffer.len) {
            return error.ArgPoolExhausted;
        }
        const args = self.args_buffer[self.args_used .. self.args_used + count];
        self.args_used += count;
        return args;
    }

    /// Allocate redirection slots
    pub fn allocRedirections(self: *CommandPool, count: usize) ![]types.Redirection {
        if (self.redirections_used + count > self.redirections_buffer.len) {
            return error.RedirectionPoolExhausted;
        }
        const redirs = self.redirections_buffer[self.redirections_used .. self.redirections_used + count];
        self.redirections_used += count;
        return redirs;
    }

    /// Allocate operator slots
    pub fn allocOperators(self: *CommandPool, count: usize) ![]types.Operator {
        if (self.operators_used + count > self.operators_buffer.len) {
            return error.OperatorPoolExhausted;
        }
        const ops = self.operators_buffer[self.operators_used .. self.operators_used + count];
        self.operators_used += count;
        return ops;
    }

    /// Duplicate a string using the pool (for small strings) or allocator (for large)
    pub fn dupeString(self: *CommandPool, str: []const u8) ![]const u8 {
        // Try pool first for small strings
        if (self.string_pool.tryAlloc(str)) |pooled| {
            return pooled;
        }
        // Fall back to allocator for large strings
        return self.allocator.dupe(u8, str);
    }

    /// Get pool statistics
    pub fn getStats(self: *const CommandPool) PoolStats {
        return .{
            .commands_used = self.commands_used,
            .commands_capacity = self.config.max_commands,
            .args_used = self.args_used,
            .args_capacity = self.args_buffer.len,
            .redirections_used = self.redirections_used,
            .redirections_capacity = self.redirections_buffer.len,
            .string_pool_used = self.string_pool.used_count,
            .string_pool_capacity = self.config.small_string_count,
        };
    }
};

pub const PoolStats = struct {
    commands_used: usize,
    commands_capacity: usize,
    args_used: usize,
    args_capacity: usize,
    redirections_used: usize,
    redirections_capacity: usize,
    string_pool_used: usize,
    string_pool_capacity: usize,

    pub fn utilizationPercent(self: PoolStats) f32 {
        const total_used = self.commands_used + self.args_used + self.redirections_used + self.string_pool_used;
        const total_capacity = self.commands_capacity + self.args_capacity + self.redirections_capacity + self.string_pool_capacity;
        if (total_capacity == 0) return 0;
        return @as(f32, @floatFromInt(total_used)) / @as(f32, @floatFromInt(total_capacity)) * 100.0;
    }
};

/// Fixed-size string pool for small strings
pub const StringPool = struct {
    allocator: std.mem.Allocator,
    buffers: [][]u8,
    used: []bool,
    buffer_size: usize,
    used_count: usize,

    pub fn init(allocator: std.mem.Allocator, count: usize, buffer_size: usize) !StringPool {
        const buffers = try allocator.alloc([]u8, count);
        errdefer allocator.free(buffers);

        const used = try allocator.alloc(bool, count);
        errdefer allocator.free(used);

        for (buffers, 0..) |*buf, i| {
            buf.* = try allocator.alloc(u8, buffer_size);
            used[i] = false;
        }

        return .{
            .allocator = allocator,
            .buffers = buffers,
            .used = used,
            .buffer_size = buffer_size,
            .used_count = 0,
        };
    }

    pub fn deinit(self: *StringPool) void {
        for (self.buffers) |buf| {
            self.allocator.free(buf);
        }
        self.allocator.free(self.buffers);
        self.allocator.free(self.used);
    }

    pub fn reset(self: *StringPool) void {
        for (self.used) |*u| {
            u.* = false;
        }
        self.used_count = 0;
    }

    /// Try to allocate a string from the pool
    /// Returns null if string is too large or pool is exhausted
    pub fn tryAlloc(self: *StringPool, str: []const u8) ?[]const u8 {
        if (str.len > self.buffer_size) return null;

        for (self.buffers, 0..) |buf, i| {
            if (!self.used[i]) {
                @memcpy(buf[0..str.len], str);
                self.used[i] = true;
                self.used_count += 1;
                return buf[0..str.len];
            }
        }
        return null;
    }
};

/// Token pool for tokenizer output
pub const TokenPool = struct {
    allocator: std.mem.Allocator,
    tokens: []Token,
    capacity: usize,
    len: usize,

    pub const Token = struct {
        type: TokenType,
        value: []const u8,
        start: usize,
        end: usize,
    };

    pub const TokenType = enum {
        word,
        pipe,
        and_op,
        or_op,
        semicolon,
        background,
        redirect_out,
        redirect_in,
        redirect_append,
        redirect_err,
        heredoc,
        herestring,
        lparen,
        rparen,
        lbrace,
        rbrace,
        newline,
        eof,
    };

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !TokenPool {
        return .{
            .allocator = allocator,
            .tokens = try allocator.alloc(Token, capacity),
            .capacity = capacity,
            .len = 0,
        };
    }

    pub fn deinit(self: *TokenPool) void {
        self.allocator.free(self.tokens);
    }

    pub fn reset(self: *TokenPool) void {
        self.len = 0;
    }

    pub fn push(self: *TokenPool, token: Token) !void {
        if (self.len >= self.capacity) {
            return error.TokenPoolExhausted;
        }
        self.tokens[self.len] = token;
        self.len += 1;
    }

    pub fn getTokens(self: *const TokenPool) []const Token {
        return self.tokens[0..self.len];
    }
};

/// Environment variable pool for temporary overrides
pub const EnvPool = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap([]const u8),
    string_pool: StringPool,

    pub fn init(allocator: std.mem.Allocator) !EnvPool {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap([]const u8).init(allocator),
            .string_pool = try StringPool.init(allocator, 32, 256),
        };
    }

    pub fn deinit(self: *EnvPool) void {
        self.entries.deinit();
        self.string_pool.deinit();
    }

    pub fn reset(self: *EnvPool) void {
        self.entries.clearRetainingCapacity();
        self.string_pool.reset();
    }

    pub fn set(self: *EnvPool, key: []const u8, value: []const u8) !void {
        const pooled_key = self.string_pool.tryAlloc(key) orelse try self.allocator.dupe(u8, key);
        const pooled_value = self.string_pool.tryAlloc(value) orelse try self.allocator.dupe(u8, value);
        try self.entries.put(pooled_key, pooled_value);
    }

    pub fn get(self: *const EnvPool, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }
};

// Tests
test "CommandPool basic operations" {
    var pool = try CommandPool.init(std.testing.allocator, .{});
    defer pool.deinit();

    // Allocate a command
    const cmd = try pool.allocCommand();
    cmd.* = .{
        .name = "echo",
        .args = &[_][]const u8{},
        .redirections = &[_]types.Redirection{},
    };

    // Allocate args
    const args = try pool.allocArgs(3);
    try std.testing.expectEqual(@as(usize, 3), args.len);

    // Check stats
    const stats = pool.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats.commands_used);
    try std.testing.expectEqual(@as(usize, 3), stats.args_used);

    // Reset and verify
    pool.reset();
    const stats2 = pool.getStats();
    try std.testing.expectEqual(@as(usize, 0), stats2.commands_used);
}

test "StringPool allocation" {
    var pool = try StringPool.init(std.testing.allocator, 4, 32);
    defer pool.deinit();

    // Allocate small strings
    const s1 = pool.tryAlloc("hello").?;
    try std.testing.expectEqualStrings("hello", s1);

    const s2 = pool.tryAlloc("world").?;
    try std.testing.expectEqualStrings("world", s2);

    // Verify different buffers
    try std.testing.expect(s1.ptr != s2.ptr);

    // Large string should fail
    const large = "x" ** 100;
    try std.testing.expect(pool.tryAlloc(large) == null);

    // Reset and reuse
    pool.reset();
    const s3 = pool.tryAlloc("reused").?;
    try std.testing.expectEqualStrings("reused", s3);
}

test "TokenPool operations" {
    var pool = try TokenPool.init(std.testing.allocator, 100);
    defer pool.deinit();

    try pool.push(.{ .type = .word, .value = "echo", .start = 0, .end = 4 });
    try pool.push(.{ .type = .word, .value = "hello", .start = 5, .end = 10 });

    const tokens = pool.getTokens();
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqualStrings("echo", tokens[0].value);

    pool.reset();
    try std.testing.expectEqual(@as(usize, 0), pool.len);
}

test "PoolStats utilization" {
    const stats = PoolStats{
        .commands_used = 5,
        .commands_capacity = 10,
        .args_used = 10,
        .args_capacity = 100,
        .redirections_used = 2,
        .redirections_capacity = 20,
        .string_pool_used = 3,
        .string_pool_capacity = 50,
    };

    const util = stats.utilizationPercent();
    // (5+10+2+3) / (10+100+20+50) * 100 = 20/180 * 100 = 11.11%
    try std.testing.expect(util > 11.0 and util < 12.0);
}
