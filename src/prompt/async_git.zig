const std = @import("std");
const git_mod = @import("git.zig");
const GitInfo = git_mod.GitInfo;
const GitModule = git_mod.GitModule;

/// Async git status fetcher with caching and timeout support
pub const AsyncGitFetcher = struct {
    allocator: std.mem.Allocator,
    git_module: GitModule,

    // Cache
    cached_info: ?CachedGitInfo,
    cache_mutex: std.Thread.Mutex,

    // Background fetch state
    fetch_thread: ?std.Thread,
    fetch_in_progress: std.atomic.Value(bool),
    fetch_cwd: ?[]const u8,

    // Configuration
    timeout_ms: u64,

    const CachedGitInfo = struct {
        info: GitInfo,
        cwd: []const u8,
        timestamp: i64, // Unix timestamp in milliseconds
        allocator: std.mem.Allocator,

        pub fn deinit(self: *CachedGitInfo) void {
            self.info.deinit();
            self.allocator.free(self.cwd);
        }
    };

    pub fn init(allocator: std.mem.Allocator) AsyncGitFetcher {
        return .{
            .allocator = allocator,
            .git_module = GitModule.init(allocator),
            .cached_info = null,
            .cache_mutex = .{},
            .fetch_thread = null,
            .fetch_in_progress = std.atomic.Value(bool).init(false),
            .fetch_cwd = null,
            .timeout_ms = 200, // 200ms timeout by default
        };
    }

    pub fn deinit(self: *AsyncGitFetcher) void {
        // Wait for background thread if running
        if (self.fetch_thread) |thread| {
            thread.join();
        }

        // Clean up cached info
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        if (self.cached_info) |*cached| {
            cached.deinit();
        }

        if (self.fetch_cwd) |cwd| {
            self.allocator.free(cwd);
        }
    }

    /// Set timeout for git operations in milliseconds
    pub fn setTimeout(self: *AsyncGitFetcher, timeout_ms: u64) void {
        self.timeout_ms = timeout_ms;
    }

    /// Get git info, either from cache or by fetching
    /// Returns cached data immediately if available, otherwise returns empty GitInfo
    /// and starts background fetch
    pub fn getInfo(self: *AsyncGitFetcher, cwd: []const u8) !GitInfo {
        const now = std.time.milliTimestamp();

        // Check cache first
        self.cache_mutex.lock();
        if (self.cached_info) |*cached| {
            // Check if cache is for same directory and not too old (< 5 seconds)
            if (std.mem.eql(u8, cached.cwd, cwd) and (now - cached.timestamp) < 5000) {
                // Return copy of cached info
                defer self.cache_mutex.unlock();
                return try self.copyGitInfo(&cached.info);
            }
        }
        self.cache_mutex.unlock();

        // Start background fetch if not already running
        if (!self.fetch_in_progress.load(.acquire)) {
            try self.startBackgroundFetch(cwd);
        }

        // Try to wait a bit for the result (with timeout)
        const start = std.time.milliTimestamp();
        while (std.time.milliTimestamp() - start < self.timeout_ms) {
            if (!self.fetch_in_progress.load(.acquire)) {
                // Fetch completed, check cache again
                self.cache_mutex.lock();
                defer self.cache_mutex.unlock();

                if (self.cached_info) |*cached| {
                    if (std.mem.eql(u8, cached.cwd, cwd)) {
                        return try self.copyGitInfo(&cached.info);
                    }
                }
                break;
            }
            std.posix.nanosleep(0, 10_000_000); // Sleep 10ms
        }

        // Timeout or no cache available - return empty info
        return GitInfo.init(self.allocator);
    }

    /// Start background fetch for git info
    fn startBackgroundFetch(self: *AsyncGitFetcher, cwd: []const u8) !void {
        // Wait for previous thread if exists
        if (self.fetch_thread) |thread| {
            thread.join();
            self.fetch_thread = null;
        }

        // Clean up old cwd
        if (self.fetch_cwd) |old_cwd| {
            self.allocator.free(old_cwd);
        }

        // Store cwd for background thread
        self.fetch_cwd = try self.allocator.dupe(u8, cwd);

        // Mark fetch as in progress
        self.fetch_in_progress.store(true, .release);

        // Spawn background thread
        self.fetch_thread = try std.Thread.spawn(.{}, backgroundFetchWorker, .{self});
    }

    /// Background worker function
    fn backgroundFetchWorker(self: *AsyncGitFetcher) void {
        defer self.fetch_in_progress.store(false, .release);

        const cwd = self.fetch_cwd orelse return;

        // Fetch git info
        var git_info = self.git_module.getInfo(cwd) catch {
            // Failed to get git info
            return;
        };

        // Update cache
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        // Clean up old cache
        if (self.cached_info) |*old_cached| {
            old_cached.deinit();
        }

        // Store new cache
        const cwd_copy = self.allocator.dupe(u8, cwd) catch {
            git_info.deinit();
            return;
        };

        self.cached_info = CachedGitInfo{
            .info = git_info,
            .cwd = cwd_copy,
            .timestamp = std.time.milliTimestamp(),
            .allocator = self.allocator,
        };
    }

    /// Copy GitInfo for returning to caller
    fn copyGitInfo(self: *AsyncGitFetcher, info: *const GitInfo) !GitInfo {
        var copy = GitInfo.init(self.allocator);

        if (info.branch) |branch| {
            copy.branch = try self.allocator.dupe(u8, branch);
        }

        if (info.commit_hash) |hash| {
            copy.commit_hash = try self.allocator.dupe(u8, hash);
        }

        copy.is_dirty = info.is_dirty;
        copy.staged_count = info.staged_count;
        copy.unstaged_count = info.unstaged_count;
        copy.untracked_count = info.untracked_count;
        copy.ahead = info.ahead;
        copy.behind = info.behind;
        copy.stash_count = info.stash_count;

        return copy;
    }

    /// Invalidate cache (useful when user runs git commands)
    pub fn invalidateCache(self: *AsyncGitFetcher) void {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        if (self.cached_info) |*cached| {
            cached.deinit();
            self.cached_info = null;
        }
    }
};
