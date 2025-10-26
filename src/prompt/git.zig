const std = @import("std");

/// Git repository information
pub const GitInfo = struct {
    branch: ?[]const u8,
    commit_hash: ?[]const u8,
    is_dirty: bool,
    staged_count: usize,
    unstaged_count: usize,
    untracked_count: usize,
    ahead: usize,
    behind: usize,
    stash_count: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GitInfo {
        return .{
            .branch = null,
            .commit_hash = null,
            .is_dirty = false,
            .staged_count = 0,
            .unstaged_count = 0,
            .untracked_count = 0,
            .ahead = 0,
            .behind = 0,
            .stash_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GitInfo) void {
        if (self.branch) |b| self.allocator.free(b);
        if (self.commit_hash) |h| self.allocator.free(h);
    }
};

/// Git integration module
pub const GitModule = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GitModule {
        return .{ .allocator = allocator };
    }

    /// Detect if current directory is in a Git repository
    pub fn isGitRepository(self: *GitModule, cwd: []const u8) bool {
        _ = self;

        // Try to open .git directory
        var dir = std.fs.openDirAbsolute(cwd, .{}) catch return false;
        defer dir.close();

        // Check for .git directory or file (for submodules/worktrees)
        dir.access(".git", .{}) catch return false;

        return true;
    }

    /// Get Git information for current directory
    pub fn getInfo(self: *GitModule, cwd: []const u8) !GitInfo {
        var info = GitInfo.init(self.allocator);

        // Check if we're in a git repository
        if (!self.isGitRepository(cwd)) {
            return info;
        }

        // Get branch name
        info.branch = self.getBranch(cwd) catch null;

        // Get commit hash
        info.commit_hash = self.getCommitHash(cwd) catch null;

        // Get status
        const status = self.getStatus(cwd) catch return info;
        defer self.allocator.free(status);

        self.parseStatus(status, &info);

        // Get ahead/behind counts
        const ahead_behind = self.getAheadBehind(cwd) catch .{ .ahead = 0, .behind = 0 };
        info.ahead = ahead_behind.ahead;
        info.behind = ahead_behind.behind;

        // Get stash count
        info.stash_count = self.getStashCount(cwd) catch 0;

        return info;
    }

    /// Get current branch name
    fn getBranch(self: *GitModule, cwd: []const u8) ![]const u8 {
        const result = try self.runGitCommand(cwd, &[_][]const u8{ "git", "branch", "--show-current" });
        defer self.allocator.free(result);

        const trimmed = std.mem.trim(u8, result, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            // Detached HEAD - try to get the hash
            return try self.allocator.dupe(u8, "HEAD");
        }

        return try self.allocator.dupe(u8, trimmed);
    }

    /// Get current commit hash (short)
    fn getCommitHash(self: *GitModule, cwd: []const u8) ![]const u8 {
        const result = try self.runGitCommand(cwd, &[_][]const u8{ "git", "rev-parse", "--short", "HEAD" });
        defer self.allocator.free(result);

        const trimmed = std.mem.trim(u8, result, &std.ascii.whitespace);
        return try self.allocator.dupe(u8, trimmed);
    }

    /// Get git status output
    fn getStatus(self: *GitModule, cwd: []const u8) ![]const u8 {
        return try self.runGitCommand(cwd, &[_][]const u8{ "git", "status", "--porcelain" });
    }

    /// Parse git status output
    fn parseStatus(self: *GitModule, status: []const u8, info: *GitInfo) void {
        _ = self;

        var line_iter = std.mem.splitScalar(u8, status, '\n');
        while (line_iter.next()) |line| {
            if (line.len < 3) continue;

            const x = line[0]; // Index status
            const y = line[1]; // Worktree status

            // Count staged files
            if (x != ' ' and x != '?') {
                info.staged_count += 1;
            }

            // Count unstaged files
            if (y != ' ' and y != '?') {
                info.unstaged_count += 1;
            }

            // Count untracked files
            if (x == '?' and y == '?') {
                info.untracked_count += 1;
            }
        }

        // Repository is dirty if there are any changes
        info.is_dirty = info.staged_count > 0 or
            info.unstaged_count > 0 or
            info.untracked_count > 0;
    }

    /// Get ahead/behind counts for current branch
    fn getAheadBehind(self: *GitModule, cwd: []const u8) !struct { ahead: usize, behind: usize } {
        const result = try self.runGitCommand(cwd, &[_][]const u8{ "git", "rev-list", "--left-right", "--count", "HEAD...@{upstream}" });
        defer self.allocator.free(result);

        const trimmed = std.mem.trim(u8, result, &std.ascii.whitespace);

        // Parse output: "ahead\tbehind"
        var parts = std.mem.splitScalar(u8, trimmed, '\t');

        const ahead_str = parts.next() orelse return .{ .ahead = 0, .behind = 0 };
        const behind_str = parts.next() orelse return .{ .ahead = 0, .behind = 0 };

        const ahead = std.fmt.parseInt(usize, ahead_str, 10) catch 0;
        const behind = std.fmt.parseInt(usize, behind_str, 10) catch 0;

        return .{ .ahead = ahead, .behind = behind };
    }

    /// Get stash count
    fn getStashCount(self: *GitModule, cwd: []const u8) !usize {
        const result = try self.runGitCommand(cwd, &[_][]const u8{ "git", "stash", "list" });
        defer self.allocator.free(result);

        // Count lines
        var count: usize = 0;
        var line_iter = std.mem.splitScalar(u8, result, '\n');
        while (line_iter.next()) |line| {
            if (line.len > 0) count += 1;
        }

        return count;
    }

    /// Run a git command and return output
    fn runGitCommand(self: *GitModule, cwd: []const u8, argv: []const []const u8) ![]const u8 {
        var child = std.process.Child.init(argv, self.allocator);
        child.cwd = cwd;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        errdefer self.allocator.free(stdout);

        _ = try child.wait();

        return stdout;
    }

    /// Find git repository root from a given path
    pub fn findRepositoryRoot(self: *GitModule, start_path: []const u8) !?[]const u8 {
        var current_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const current_path = try std.fs.realpath(start_path, &current_path_buf);

        var path = try self.allocator.dupe(u8, current_path);
        defer self.allocator.free(path);

        while (true) {
            // Check if .git exists in current directory
            var dir = std.fs.openDirAbsolute(path, .{}) catch break;
            defer dir.close();

            dir.access(".git", .{}) catch {
                // No .git here, go up one level
                const parent = std.fs.path.dirname(path) orelse break;
                const parent_copy = try self.allocator.dupe(u8, parent);
                self.allocator.free(path);
                path = parent_copy;
                continue;
            };

            // Found it!
            return try self.allocator.dupe(u8, path);
        }

        return null;
    }
};
