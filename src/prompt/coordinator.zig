const std = @import("std");
const types = @import("types.zig");
const renderer_mod = @import("renderer.zig");
const git_mod = @import("git.zig");
const sysinfo_mod = @import("sysinfo.zig");
const async_git_mod = @import("async_git.zig");

const PromptContext = types.PromptContext;
const PromptTemplate = types.PromptTemplate;
const PromptRenderer = renderer_mod.PromptRenderer;
const GitModule = git_mod.GitModule;
const SystemInfo = sysinfo_mod.SystemInfo;
const AsyncGitFetcher = async_git_mod.AsyncGitFetcher;

/// Prompt Coordinator orchestrates all prompt-related components.
///
/// This module centralizes prompt rendering logic to keep shell.zig focused
/// on core state management. It manages:
/// - Prompt context building
/// - Git status fetching (sync and async)
/// - System info gathering
/// - Prompt rendering with templates
pub const PromptCoordinator = struct {
    allocator: std.mem.Allocator,
    renderer: ?PromptRenderer,
    context: PromptContext,
    async_git: AsyncGitFetcher,
    template: PromptTemplate,
    is_interactive: bool,
    simple_mode: bool,

    const Self = @This();

    /// Initialize the prompt coordinator.
    pub fn init(allocator: std.mem.Allocator, template: PromptTemplate) Self {
        return Self{
            .allocator = allocator,
            .renderer = null,
            .context = PromptContext.initDefault(),
            .async_git = AsyncGitFetcher.init(allocator),
            .template = template,
            .is_interactive = true,
            .simple_mode = false,
        };
    }

    /// Deinitialize and free resources.
    pub fn deinit(self: *Self) void {
        if (self.renderer) |*r| {
            r.deinit();
        }
        self.async_git.deinit();
    }

    /// Set interactive mode (affects whether prompts are rendered).
    pub fn setInteractive(self: *Self, interactive: bool) void {
        self.is_interactive = interactive;
    }

    /// Set simple mode (no colors, basic output).
    pub fn setSimpleMode(self: *Self, simple: bool) void {
        self.simple_mode = simple;
        if (self.renderer) |*r| {
            r.setSimpleMode(simple);
        }
    }

    /// Update the prompt template.
    pub fn setTemplate(self: *Self, template: PromptTemplate) void {
        self.template = template;
        // Renderer needs to be recreated with new template
        if (self.renderer) |*r| {
            r.deinit();
            self.renderer = null;
        }
    }

    /// Update the prompt context with current state.
    pub fn updateContext(
        self: *Self,
        cwd: []const u8,
        home: ?[]const u8,
        last_exit_code: i32,
        username: []const u8,
        hostname: []const u8,
    ) void {
        self.context.current_dir = cwd;
        self.context.home_dir = home;
        self.context.last_exit_code = last_exit_code;
        self.context.username = username;
        self.context.hostname = hostname;
    }

    /// Update git information in the context.
    pub fn updateGitInfo(
        self: *Self,
        branch: ?[]const u8,
        dirty: bool,
        ahead: usize,
        behind: usize,
    ) void {
        self.context.git_branch = branch;
        self.context.git_dirty = dirty;
        self.context.git_ahead = ahead;
        self.context.git_behind = behind;
    }

    /// Start async git fetch for the current directory.
    pub fn startAsyncGitFetch(self: *Self, cwd: []const u8) void {
        self.async_git.startFetch(cwd);
    }

    /// Check if async git results are ready and update context.
    pub fn checkAsyncGit(self: *Self) bool {
        if (self.async_git.getResult()) |result| {
            self.context.git_branch = result.branch;
            self.context.git_dirty = result.is_dirty;
            self.context.git_ahead = result.ahead;
            self.context.git_behind = result.behind;
            self.context.git_staged = result.staged;
            self.context.git_unstaged = result.unstaged;
            self.context.git_untracked = result.untracked;
            return true;
        }
        return false;
    }

    /// Render the prompt string.
    pub fn render(self: *Self, terminal_width: usize) ![]const u8 {
        if (!self.is_interactive) {
            return try self.allocator.dupe(u8, "$ ");
        }

        // Initialize renderer if needed
        if (self.renderer == null) {
            self.renderer = try PromptRenderer.init(self.allocator, self.template);
            if (self.simple_mode) {
                self.renderer.?.setSimpleMode(true);
            }
        }

        return try self.renderer.?.render(&self.context, terminal_width);
    }

    /// Render a simple fallback prompt (for error cases).
    pub fn renderFallback(self: *Self) []const u8 {
        _ = self;
        return "$ ";
    }

    /// Get the current context (read-only).
    pub fn getContext(self: *const Self) *const PromptContext {
        return &self.context;
    }

    /// Get mutable context for direct updates.
    pub fn getContextMut(self: *Self) *PromptContext {
        return &self.context;
    }
};

/// Build a prompt context from environment and system state.
pub fn buildContext(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    home: ?[]const u8,
    last_exit_code: i32,
) !PromptContext {
    var ctx = PromptContext.initDefault();

    ctx.current_dir = cwd;
    ctx.home_dir = home;
    ctx.last_exit_code = last_exit_code;

    // Get user info
    const user_info = SystemInfo.getUserInfo(allocator);
    ctx.username = user_info.username;
    ctx.hostname = user_info.hostname;
    ctx.is_root = user_info.is_root;

    return ctx;
}

// ========================================
// Tests
// ========================================

test "PromptCoordinator init and deinit" {
    const allocator = std.testing.allocator;
    var coord = PromptCoordinator.init(allocator, PromptTemplate.initDefault());
    defer coord.deinit();

    try std.testing.expect(coord.is_interactive);
    try std.testing.expect(!coord.simple_mode);
}

test "PromptCoordinator updateContext" {
    const allocator = std.testing.allocator;
    var coord = PromptCoordinator.init(allocator, PromptTemplate.initDefault());
    defer coord.deinit();

    coord.updateContext("/home/user", "/home/user", 0, "testuser", "localhost");

    try std.testing.expectEqualStrings("/home/user", coord.context.current_dir);
    try std.testing.expectEqual(@as(i32, 0), coord.context.last_exit_code);
}

test "PromptCoordinator setSimpleMode" {
    const allocator = std.testing.allocator;
    var coord = PromptCoordinator.init(allocator, PromptTemplate.initDefault());
    defer coord.deinit();

    coord.setSimpleMode(true);
    try std.testing.expect(coord.simple_mode);
}
