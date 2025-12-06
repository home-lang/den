const std = @import("std");

/// Memory pool for command execution
/// Uses arena allocation for efficient allocation and deallocation of
/// short-lived objects during command parsing and execution.
pub const CommandMemoryPool = struct {
    arena: std.heap.ArenaAllocator,
    parent_allocator: std.mem.Allocator,
    allocations: usize,
    bytes_allocated: usize,

    pub fn init(parent_allocator: std.mem.Allocator) CommandMemoryPool {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .parent_allocator = parent_allocator,
            .allocations = 0,
            .bytes_allocated = 0,
        };
    }

    pub fn deinit(self: *CommandMemoryPool) void {
        self.arena.deinit();
    }

    /// Get the arena allocator for command-scoped allocations
    pub fn allocator(self: *CommandMemoryPool) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Reset the arena for the next command
    /// This deallocates all memory from the previous command at once
    pub fn reset(self: *CommandMemoryPool) void {
        // Track stats before reset
        self.allocations = 0;
        self.bytes_allocated = 0;

        // Free the arena and reinit
        _ = self.arena.reset(.retain_capacity);
    }

    /// Allocate memory that will be freed on reset
    pub fn alloc(self: *CommandMemoryPool, comptime T: type, n: usize) ![]T {
        const slice = try self.arena.allocator().alloc(T, n);
        self.allocations += 1;
        self.bytes_allocated += n * @sizeOf(T);
        return slice;
    }

    /// Duplicate a slice
    pub fn dupe(self: *CommandMemoryPool, comptime T: type, s: []const T) ![]T {
        const slice = try self.arena.allocator().dupe(T, s);
        self.allocations += 1;
        self.bytes_allocated += s.len * @sizeOf(T);
        return slice;
    }

    /// Duplicate a null-terminated string
    pub fn dupeZ(self: *CommandMemoryPool, s: []const u8) ![:0]u8 {
        const slice = try self.arena.allocator().dupeZ(u8, s);
        self.allocations += 1;
        self.bytes_allocated += s.len + 1;
        return slice;
    }

    /// Get stats about current pool usage
    pub fn getStats(self: *const CommandMemoryPool) PoolStats {
        return .{
            .allocations = self.allocations,
            .bytes_allocated = self.bytes_allocated,
        };
    }
};

pub const PoolStats = struct {
    allocations: usize,
    bytes_allocated: usize,
};

/// Pipeline memory pool for managing pipeline-specific allocations
/// Provides separate arenas for each stage of pipeline execution
pub const PipelineMemoryPool = struct {
    stages: [16]?std.heap.ArenaAllocator,
    stage_count: usize,
    parent_allocator: std.mem.Allocator,

    pub fn init(parent_allocator: std.mem.Allocator) PipelineMemoryPool {
        return .{
            .stages = [_]?std.heap.ArenaAllocator{null} ** 16,
            .stage_count = 0,
            .parent_allocator = parent_allocator,
        };
    }

    pub fn deinit(self: *PipelineMemoryPool) void {
        for (&self.stages) |*stage_opt| {
            if (stage_opt.*) |*stage| {
                stage.deinit();
            }
        }
    }

    /// Get or create an arena for a pipeline stage
    pub fn getStageAllocator(self: *PipelineMemoryPool, stage: usize) !std.mem.Allocator {
        if (stage >= self.stages.len) {
            return error.TooManyPipelineStages;
        }

        if (self.stages[stage] == null) {
            self.stages[stage] = std.heap.ArenaAllocator.init(self.parent_allocator);
            self.stage_count = @max(self.stage_count, stage + 1);
        }

        return self.stages[stage].?.allocator();
    }

    /// Reset all stage arenas
    pub fn reset(self: *PipelineMemoryPool) void {
        for (&self.stages) |*stage_opt| {
            if (stage_opt.*) |*stage| {
                _ = stage.reset(.retain_capacity);
            }
        }
    }
};

/// Expansion memory pool for variable/brace/glob expansion
/// Uses a stack of arenas for nested expansions
pub const ExpansionMemoryPool = struct {
    stack: [8]std.heap.ArenaAllocator,
    depth: usize,
    parent_allocator: std.mem.Allocator,

    pub fn init(parent_allocator: std.mem.Allocator) ExpansionMemoryPool {
        var pool: ExpansionMemoryPool = .{
            .stack = undefined,
            .depth = 0,
            .parent_allocator = parent_allocator,
        };
        // Initialize first arena for base expansions
        pool.stack[0] = std.heap.ArenaAllocator.init(parent_allocator);
        pool.depth = 1;
        return pool;
    }

    pub fn deinit(self: *ExpansionMemoryPool) void {
        var i: usize = 0;
        while (i < self.depth) : (i += 1) {
            self.stack[i].deinit();
        }
    }

    /// Push a new expansion level
    pub fn push(self: *ExpansionMemoryPool) !std.mem.Allocator {
        if (self.depth >= self.stack.len) {
            return error.ExpansionDepthExceeded;
        }
        self.stack[self.depth] = std.heap.ArenaAllocator.init(self.parent_allocator);
        self.depth += 1;
        return self.stack[self.depth - 1].allocator();
    }

    /// Pop an expansion level (frees all memory at that level)
    pub fn pop(self: *ExpansionMemoryPool) void {
        if (self.depth > 1) {
            self.depth -= 1;
            self.stack[self.depth].deinit();
        }
    }

    /// Get current level allocator
    pub fn currentAllocator(self: *ExpansionMemoryPool) std.mem.Allocator {
        return self.stack[self.depth - 1].allocator();
    }

    /// Reset to base level
    pub fn reset(self: *ExpansionMemoryPool) void {
        // Free all levels except base
        while (self.depth > 1) {
            self.depth -= 1;
            self.stack[self.depth].deinit();
        }
        // Reset base arena
        _ = self.stack[0].reset(.retain_capacity);
    }
};

test "CommandMemoryPool basic usage" {
    var pool = CommandMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const str = try pool.dupe(u8, "hello");
    try std.testing.expectEqualStrings("hello", str);

    const stats = pool.getStats();
    try std.testing.expect(stats.allocations == 1);
    try std.testing.expect(stats.bytes_allocated == 5);

    pool.reset();
    const new_stats = pool.getStats();
    try std.testing.expect(new_stats.allocations == 0);
}

test "PipelineMemoryPool stages" {
    var pool = PipelineMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const alloc0 = try pool.getStageAllocator(0);
    const alloc1 = try pool.getStageAllocator(1);

    const s0 = try alloc0.dupe(u8, "stage0");
    const s1 = try alloc1.dupe(u8, "stage1");

    try std.testing.expectEqualStrings("stage0", s0);
    try std.testing.expectEqualStrings("stage1", s1);
}

test "ExpansionMemoryPool nesting" {
    var pool = ExpansionMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const base = pool.currentAllocator();
    _ = try base.dupe(u8, "base");

    _ = try pool.push();
    const nested = pool.currentAllocator();
    _ = try nested.dupe(u8, "nested");

    pool.pop();
    // After pop, nested allocations are freed
}
